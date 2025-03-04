defmodule Indexer.BufferedTask do
  @moduledoc """
  Provides a behaviour for batched task running with retries.

  ## Named Arguments

  Named arguments are required and are passed in the list that is the second element of the tuple.

    * `:flush_interval` - The interval in milliseconds to flush the buffer.
    * `:max_concurrency` - The maximum number of tasks to run concurrently at any give time.
    * `:poll` - poll for new records when all records are processed
    * `:max_batch_size` - The maximum batch passed to `c:run/2`.
    * `:memory_monitor` - The `Indexer.Memory.Monitor` `t:GenServer.server/0` to register as
      `Indexer.Memory.Monitor.shrinkable/0` with.
    * `:task_supervisor` - The `Task.Supervisor` name to spawn tasks under.

  ## Options

  Options are optional and are passed in the list that is second element of the tuple.

    * `:name` - The registered name for the new process.

  ## Callbacks

  `c:init/2` is used for a task to populate its buffer on boot with an initial set of entries.

  For example, the following callback would buffer all unfetched account balances on startup:

      def init(initial, reducer) do
        Chain.stream_unfetched_balances([:hash], initial, fn %{hash: hash}, acc ->
          reducer.(Hash.to_string(hash), acc)
        end)
      end

  `c:init/2` may be long-running and allows concurrent calls to `Explorer.BufferedTask.buffer/2` for on-demand entries.
  As concurrency becomes available, `c:run/2` of the task is invoked, with a list of batched entries to be processed.

  For example, the `c:run/2` for above `c:init/2` could be written:

      def run(string_hashes, _state) do
        case EthereumJSONRPC.fetch_balances_by_hash(string_hashes) do
          {:ok, results} -> :ok = update_balances(results)
          {:error, _reason} -> :retry
        end
      end

  If a task crashes, it will be retried automatically. Tasks may also be programmatically retried by returning `:retry`
  from `c:run/2`.
  """

  use GenServer

  require Logger

  import Indexer.Logger, only: [process: 1]

  alias Indexer.{BoundQueue, BufferedTask, Memory}

  @enforce_keys [
    :callback_module,
    :callback_module_state,
    :task_supervisor,
    :flush_interval,
    :max_batch_size
  ]
  defstruct init_task: nil,
            flush_timer: nil,
            callback_module: nil,
            callback_module_state: nil,
            task_supervisor: nil,
            flush_interval: nil,
            poll_interval: nil,
            max_batch_size: nil,
            max_concurrency: nil,
            poll: false,
            dedup_entries: false,
            metadata: [],
            current_buffer: [],
            bound_queue: %BoundQueue{},
            task_ref_to_batch: %{}

  @typedoc """
  Entry passed to `t:reducer/2` in `c:init/2` and grouped together into a list as `t:entries/0` passed to `c:run/2`.
  """
  @type entry :: term()

  @typedoc """
  List of `t:entry/0` passed to `c:run/2`.
  """
  @type entries :: [entry, ...]

  @typedoc """
  The initial `t:accumulator/0` for `c:init/2`.
  """
  @opaque initial :: {0, []}

  @typedoc """
  The accumulator passed through the `t:reducer/0` for `c:init/2`.
  """
  @opaque accumulator :: {non_neg_integer(), list()}

  @typedoc """
  Reducer for `c:init/2`.

  Accepts entry generated by callback module and passes through `accumulator`.  `Explorer.BufferTask` itself will decide
  how to integrate `entry` into `accumulator` or to run `c:run/2`.
  """
  @type reducer :: (entry, accumulator -> accumulator)

  @typedoc """
  Callback module controlled state.  Can be used to store extra information needed for each `run/2`
  """
  @type state :: term()

  @doc """
  Populates a task's buffer on boot with an initial set of entries.

  For example, the following callback would buffer all unfetched account balances on startup:

      def init(initial, reducer, state) do
        final = Chain.stream_unfetched_balances([:hash], initial, fn %{hash: hash}, acc ->
          reducer.(Hash.to_string(hash), acc)
        end)

        {final, state}
      end

  The `init/2` operation may be long-running as it is run in a separate process and allows concurrent calls to
  `Explorer.BufferedTask.buffer/2` for on-demand entries.
  """
  @callback init(initial, reducer, state) :: accumulator

  @doc """
  Invoked as concurrency becomes available with a list of batched entries to be processed.

  For example, the `c:run/2` callback for the example `c:init/2` callback could be written:

      def run(string_hashes, _state) do
        case EthereumJSONRPC.fetch_balances_by_hash(string_hashes) do
          {:ok, results} -> :ok = update_balances(results)
          {:error, _reason} -> :retry
        end
      end

  If a task crashes, it will be retried automatically. Tasks may also be programmatically retried by returning `:retry`
  from `c:run/2`.

  ## Returns

   * `:ok` - run was successful
   * `:retry` - run should be retried after it failed
   * `{:retry, new_entries :: list}` - run should be retried with `new_entries`

  """
  @callback run(entries, state) :: :ok | :retry | {:retry, new_entries :: list}

  @doc """
  Buffers list of entries for future async execution.
  """
  @spec buffer(GenServer.name(), entries(), timeout()) :: :ok
  def buffer(server, entries, timeout \\ 5000) when is_list(entries) do
    GenServer.call(server, {:buffer, entries}, timeout)
  end

  def child_spec([init_arguments]) do
    child_spec([init_arguments, []])
  end

  def child_spec([_init_arguments, _gen_server_options] = start_link_arguments) do
    default = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments}
    }

    Supervisor.child_spec(default, [])
  end

  @doc false
  def debug_count(server) do
    GenServer.call(server, :debug_count)
  end

  @doc """
  Starts `callback_module` as a buffered task.

  Takes a tuple of the callback module and list of named arguments and options, much like the format accepted for
  `Supervisor.start_link/2`, `Supervisor.init/2` and `Supervisor.child_spec/2`.

  ## Named Arguments

  Named arguments are required and are passed in the list that is the second element of the tuple.

    * `:flush_interval` - The interval in milliseconds to flush the buffer.
    * `:max_concurrency` - The maximum number of tasks to run concurrently at any give time.
    * `:max_batch_size` - The maximum batch passed to `c:run/2`.
    * `:task_supervisor` - The `Task.Supervisor` name to spawn tasks under.

  ## Options

  Options are optional and are passed in the list that is second element of the tuple.

    * `:name` - The registered name for the new process.
    * `:metadata` - `Logger.metadata/1` to det in teh `Indexer.BufferedTask` process and any child processes.

  """
  @spec start_link(
          {callback_module :: module,
           [
             {:flush_interval, timeout()}
             | {:poll_interval, timeout()}
             | {:max_batch_size, pos_integer()}
             | {:max_concurrency, pos_integer()}
             | {:dedup_entries, boolean()}
             | {:memory_monitor, GenServer.name()}
             | {:name, GenServer.name()}
             | {:task_supervisor, GenServer.name()}
             | {:state, state}
           ]}
        ) :: {:ok, pid()} | {:error, {:already_started, pid()}}
  def start_link({module, base_init_opts}, genserver_opts \\ []) do
    default_opts = Application.get_all_env(:indexer)
    init_opts = Keyword.merge(default_opts, base_init_opts)

    GenServer.start_link(__MODULE__, {module, init_opts}, genserver_opts)
  end

  def init({callback_module, opts}) do
    send(self(), :initial_stream)

    shrinkable(opts)

    metadata = Keyword.get(opts, :metadata, [])
    Logger.metadata(metadata)

    state = %BufferedTask{
      callback_module: callback_module,
      callback_module_state: Keyword.fetch!(opts, :state),
      poll: Keyword.get(opts, :poll, false),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      flush_interval: Keyword.fetch!(opts, :flush_interval),
      poll_interval: Keyword.get(opts, :poll_interval, :timer.seconds(3)),
      dedup_entries: Keyword.get(opts, :dedup_entries, false),
      max_batch_size: Keyword.fetch!(opts, :max_batch_size),
      max_concurrency: Keyword.fetch!(opts, :max_concurrency),
      metadata: metadata
    }

    {:ok, state}
  end

  def handle_info(:initial_stream, state) do
    {:noreply, do_initial_stream(state)}
  end

  def handle_info(:flush, state) do
    {:noreply, flush(state)}
  end

  def handle_info({ref, :ok}, %{init_task: ref} = state) do
    {:noreply, state}
  end

  def handle_info({ref, :ok}, state) do
    {:noreply, drop_task(state, ref)}
  end

  def handle_info({ref, :retry}, state) do
    {:noreply, drop_task_and_retry(state, ref)}
  end

  def handle_info({ref, {:retry, retryable_entries}}, state) do
    {:noreply, drop_task_and_retry(state, ref, retryable_entries)}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %BufferedTask{init_task: ref} = state) do
    {:noreply, %{state | init_task: :complete}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop_task_and_retry(state, ref)}
  end

  def handle_call({:buffer, entries}, _from, state) do
    {:reply, :ok, buffer_entries(state, entries)}
  end

  def handle_call(
        :debug_count,
        _from,
        %BufferedTask{
          current_buffer: current_buffer,
          bound_queue: bound_queue,
          max_batch_size: max_batch_size,
          task_ref_to_batch: task_ref_to_batch
        } = state
      ) do
    count = length(current_buffer) + Enum.count(bound_queue) * max_batch_size

    {:reply, %{buffer: count, tasks: Enum.count(task_ref_to_batch)}, state}
  end

  def handle_call({:push_back, entries}, _from, state) when is_list(entries) do
    new_state =
      state
      |> push_back(entries)
      |> spawn_next_batch()

    {:reply, :ok, new_state}
  end

  def handle_call(:shrink, _from, %__MODULE__{bound_queue: bound_queue} = state) do
    {reply, shrunk_state} =
      case BoundQueue.shrink(bound_queue) do
        {:error, :minimum_size} = error ->
          {error, state}

        {:ok, shrunk_bound_queue} ->
          {:ok, %__MODULE__{state | bound_queue: shrunk_bound_queue}}
      end

    {:reply, reply, shrunk_state, :hibernate}
  end

  def handle_call(:shrunk?, _from, %__MODULE__{bound_queue: bound_queue} = state) do
    {:reply, BoundQueue.shrunk?(bound_queue), state}
  end

  defp drop_task(state, ref) do
    spawn_next_batch(%BufferedTask{state | task_ref_to_batch: Map.delete(state.task_ref_to_batch, ref)})
  end

  defp drop_task_and_retry(%BufferedTask{task_ref_to_batch: task_ref_to_batch} = state, ref, new_batch \\ nil) do
    batch = Map.fetch!(task_ref_to_batch, ref)

    state
    |> drop_task(ref)
    |> push_back(new_batch || batch)
  end

  defp buffer_entries(state, []), do: state

  defp buffer_entries(state, entries) do
    %{state | current_buffer: [entries | state.current_buffer]}
  end

  defp do_initial_stream(
         %BufferedTask{
           callback_module: callback_module,
           callback_module_state: callback_module_state,
           max_batch_size: max_batch_size,
           task_supervisor: task_supervisor,
           metadata: metadata
         } = state
       ) do
    parent = self()

    task =
      Task.Supervisor.async(task_supervisor, fn ->
        Logger.metadata(metadata)

        try do
          {0, []}
          |> callback_module.init(
            fn
              entry, {len, acc} when len + 1 >= max_batch_size ->
                entries = Enum.reverse([entry | acc])
                push_back(parent, entries)

                {0, []}

              entry, {len, acc} ->
                {len + 1, [entry | acc]}
            end,
            callback_module_state
          )
          |> catchup_remaining(max_batch_size, parent)
        rescue
          err ->
            Logger.warn(fn ->
              "Failed to initialize buffered task '#{Exception.format(:error, err, __STACKTRACE__)}'."
            end)

            :ok
        end
      end)

    schedule_next_buffer_flush(%BufferedTask{state | init_task: task.ref})
  end

  defp catchup_remaining({0, []}, _max_batch_size, _pid), do: :ok

  defp catchup_remaining({len, batch}, max_batch_size, pid)
       when is_integer(len) and is_list(batch) and is_integer(max_batch_size) and is_pid(pid) do
    push_back(pid, Enum.reverse(batch))

    :ok
  end

  defp push_back(pid, entries) when is_pid(pid) and is_list(entries) do
    GenServer.call(pid, {:push_back, entries})
  end

  defp push_back(%BufferedTask{bound_queue: bound_queue} = state, entries) when is_list(entries) do
    entries_to_push = dedup_entries(state, entries)

    new_bound_queue =
      case BoundQueue.push_back_until_maximum_size(bound_queue, entries_to_push) do
        {new_bound_queue, []} ->
          new_bound_queue

        {%BoundQueue{maximum_size: maximum_size} = new_bound_queue, remaining_entries} ->
          Logger.warn(fn ->
            [
              "BufferedTask #{process(self())} bound queue is at maximum size (#{to_string(maximum_size)}) and #{remaining_entries |> Enum.count() |> to_string()} entries could not be added."
            ]
          end)

          new_bound_queue
      end

    %BufferedTask{state | bound_queue: new_bound_queue}
  end

  defp dedup_entries(%BufferedTask{dedup_entries: false}, entries), do: entries

  defp dedup_entries(
         %BufferedTask{dedup_entries: true, task_ref_to_batch: task_ref_to_batch, bound_queue: bound_queue},
         entries
       ) do
    running_entries =
      task_ref_to_batch
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> MapSet.new()

    queued_entries = MapSet.new(bound_queue)

    entries
    |> MapSet.new()
    |> MapSet.difference(running_entries)
    |> MapSet.difference(queued_entries)
    |> MapSet.to_list()
  end

  defp take_batch(%BufferedTask{bound_queue: bound_queue, max_batch_size: max_batch_size} = state) do
    {batch, new_bound_queue} = take_batch(bound_queue, max_batch_size)
    {batch, %BufferedTask{state | bound_queue: new_bound_queue}}
  end

  defp take_batch(%BoundQueue{} = bound_queue, max_batch_size) do
    take_batch(bound_queue, max_batch_size, [])
  end

  defp take_batch(%BoundQueue{} = bound_queue, 0, acc) do
    {Enum.reverse(acc), bound_queue}
  end

  defp take_batch(%BoundQueue{} = bound_queue, remaining, acc) do
    case BoundQueue.pop_front(bound_queue) do
      {:ok, {entry, new_bound_queue}} ->
        take_batch(new_bound_queue, remaining - 1, [entry | acc])

      {:error, :empty} ->
        take_batch(bound_queue, 0, acc)
    end
  end

  # get more work from `init/2`
  defp schedule_next(%BufferedTask{poll: true, bound_queue: %BoundQueue{size: 0}} = state) do
    timer = Process.send_after(self(), :initial_stream, state.poll_interval)
    %{state | flush_timer: timer}
  end

  # was shrunk and was out of work, get more work from `init/2`
  defp schedule_next(%BufferedTask{bound_queue: %BoundQueue{size: 0, maximum_size: maximum_size}} = state)
       when maximum_size != nil do
    Logger.info(fn ->
      [
        "BufferedTask #{process(self())} ran out of work, but work queue was shrunk to save memory, so restoring lost work from `c:init/2`."
      ]
    end)

    do_initial_stream(state)
  end

  # was not shrunk or not out of work
  defp schedule_next(%BufferedTask{} = state) do
    schedule_next_buffer_flush(state)
  end

  defp schedule_next_buffer_flush(state) do
    timer = Process.send_after(self(), :flush, state.flush_interval)
    %{state | flush_timer: timer}
  end

  defp shrinkable(options) do
    case Keyword.get(options, :memory_monitor) do
      nil -> :ok
      memory_monitor -> Memory.Monitor.shrinkable(memory_monitor)
    end
  end

  defp spawn_next_batch(
         %BufferedTask{
           bound_queue: bound_queue,
           callback_module: callback_module,
           callback_module_state: callback_module_state,
           max_concurrency: max_concurrency,
           task_ref_to_batch: task_ref_to_batch,
           task_supervisor: task_supervisor,
           metadata: metadata
         } = state
       ) do
    if Enum.count(task_ref_to_batch) < max_concurrency and not Enum.empty?(bound_queue) do
      {batch, new_state} = take_batch(state)

      %Task{ref: ref} =
        Task.Supervisor.async_nolink(task_supervisor, __MODULE__, :log_run, [
          %{
            metadata: metadata,
            callback_module: callback_module,
            batch: batch,
            callback_module_state: callback_module_state
          }
        ])

      %BufferedTask{new_state | task_ref_to_batch: Map.put(task_ref_to_batch, ref, batch)}
    else
      state
    end
  end

  # only public so that `Task.Supervisor.async_nolink` can call it
  @doc false
  def log_run(%{
        metadata: metadata,
        callback_module: callback_module,
        batch: batch,
        callback_module_state: callback_module_state
      }) do
    Logger.metadata(metadata)
    callback_module.run(batch, callback_module_state)
  end

  defp flush(%BufferedTask{current_buffer: []} = state) do
    state
    |> spawn_next_batch()
    |> schedule_next()
  end

  defp flush(%BufferedTask{current_buffer: current} = state) do
    entries = List.flatten(current)

    %BufferedTask{state | current_buffer: []}
    |> push_back(entries)
    |> flush()
  end
end
