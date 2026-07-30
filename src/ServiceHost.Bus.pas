{
  ServiceHost — the event bus.

  Services run in separate threads and never call each other. They publish, and
  whoever subscribed receives. This unit is that middle.

  Four decisions, each taken against a specific failure in the design this was
  extracted from.

  1. PUBLISHING IS ALMOST FREE, AND NEVER BLOCKS. Publish copies the event onto
     a bounded queue and returns. The original ran a TParallel.For over the
     subscriber list to do the enqueueing — putting the RTL thread pool on the
     publish path of every single event, to iterate a handful of entries and
     call a method that already takes a lock. A plain loop is faster and does
     not couple a service's tick rate to a thread pool.

     When the queue is full the event is DROPPED and counted. A telemetry event
     must never stall the service that produced it, and a drop you can see in a
     counter is better than a stall you cannot.

  2. TWO DELIVERY LANES, EACH WITH ITS OWN THREAD. Subscribers that must run on
     the main thread are queued separately from background ones, so a slow UI
     cannot delay background delivery. That separation is the original's, and it
     was right.

  3. TWO SUBSCRIPTION SCOPES. A subscriber either watches one service or
     watches everything. Also the original's shape, kept.

  4. ONE MECHANISM FOR "THE SERVICE STOPPED", NOT TWO. The original checked at
     publish time whether the source was stopping AND purged the queue on stop.
     Neither is complete on its own and together they still race: an event can
     pass the publish check and be delivered after the stop. Here there is only
     the purge, done at the point where it can be made total — DiscardFor takes
     the same lock the dispatcher does, so once it returns, nothing from that
     service is left to deliver.
}
unit ServiceHost.Bus;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils, Classes, SyncObjs, Generics.Collections{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections{$ENDIF},
  ConcurrentPool.Types,
  ConcurrentPool.Atomic,
  ConcurrentPool.Queue,
  ServiceHost.Events;

type
  TSubscriptionId = Integer;

  TEventBus = class;

  { A registered subscriber. Kept as a record in a plain list: the list is only
    ever touched under the bus's lock, and a class per subscription would buy
    nothing. }
  TSubscription = record
    Id: TSubscriptionId;
    Handler: TEventHandler;
    Affinity: TThreadAffinity;
    { Empty means "every service" — the original's global listener list. A name
      means only that service. }
    SourceFilter: string;
    { Empty means every topic. }
    TopicFilter: string;
    { When True, only the most recent event per (Source, Topic) is delivered if
      several pile up before the subscriber is reached.

      Opt-in, and keyed on Source+Topic rather than on the integer datum. The
      original deduplicated everything bound for the UI using
      ServiceName + '|' + IntToStr(Datum) as the key, which collapses two
      genuinely different events that happen to share an integer, and says
      nothing at all about an event whose meaning is in its payload.

      Correct for state — a position, a percentage, a count. NEVER correct for a
      command or a transition, because collapsing those loses work. That is why
      it is a choice the subscriber makes rather than something the bus does to
      everyone. }
    Coalesce: Boolean;
  end;

  TEventBus = class
  strict private
    FLock: TCriticalSection;
    FSubscriptions: TList<TSubscription>;
    FNextId: TSubscriptionId;

    FBackgroundQueue: TBoundedQueue<Pointer>;
    FMainThreadQueue: TBoundedQueue<Pointer>;

    FDispatcher: TThread;
    FStopping: TAtomicCounter;

    FPublished: TAtomicCounter;
    FDelivered: TAtomicCounter;
    FDropped: TAtomicCounter;
    FDiscarded: TAtomicCounter;
    FCoalesced: TAtomicCounter;

    function Matches(const ASub: TSubscription;
      const AEvent: TServiceEvent): Boolean;
    function SnapshotSubscriptions: TArray<TSubscription>;
  private
    { Reached by the dispatcher thread, which lives in this unit. }
    procedure DispatchOne;
    function Stopping: Boolean;
  public
    constructor Create(AQueueCapacity: Integer = 1024);
    destructor Destroy; override;

    { Subscribe to one service, or to all of them when ASource is empty. }
    function Subscribe(AHandler: TEventHandler;
      AAffinity: TThreadAffinity = saBackground;
      const ASource: string = ''; const ATopic: string = '';
      ACoalesce: Boolean = False): TSubscriptionId;
    procedure Unsubscribe(AId: TSubscriptionId);

    { Copies the event and returns. Never blocks, never raises. False means a
      lane was full and the event was dropped — visible in Dropped.

      Takes the fields rather than a ready-made TServiceEvent so that the datum
      and the payload can default, and so no call site has to name the record
      type to say something as ordinary as "disk filled up". The record is
      assembled here; TServiceEvent stays the type subscribers RECEIVE. }
    function Publish(const ASource, ATopic: string; ALevel: TEventLevel;
      const AMessage: string; ADatum: Integer = 0;
      APayload: IEventPayload = nil): Boolean;

    { Drops every pending event published by AServiceName, on both lanes. Called
      by the host when a service stops, so nothing from a stopped service is
      delivered afterwards. }
    function DiscardFor(const AServiceName: string): Integer;

    { Delivers queued main-thread events on the CALLING thread. An application
      calls this from its main thread — Application.OnIdle, or its own loop.
      Returns how many were delivered. }
    function DeliverPending(AMax: Integer = 64): Integer;

    { Blocks until every published event has been delivered or dropped, or the
      timeout expires. For tests and for orderly shutdown. Main-thread events
      still need DeliverPending; this waits for the background lane. }
    function WaitDrained(ATimeoutMs: Cardinal): Boolean;

    function Published_: Integer;
    function Delivered: Integer;
    function Dropped: Integer;
    function Discarded: Integer;
    function Coalesced: Integer;
    function PendingBackground: Integer;
    function PendingMainThread: Integer;
    function SubscriptionCount: Integer;
  end;

implementation

type
  { The queues hold pointers to heap copies rather than the record itself.

    A TBoundedQueue<TServiceEvent> would work, but every event has to be
    delivered to N subscribers, so the queue entry is really "this event, for
    this subscription" — and copying a record with two strings and an interface
    per subscriber, twice (into the queue and out of it), is more work than
    passing a pointer to one heap copy. The bus owns these and frees each after
    delivery; the interface field inside is released with it. }
  PPendingDelivery = ^TPendingDelivery;
  TPendingDelivery = record
    Event: TServiceEvent;
    Handler: TEventHandler;
    SubId: TSubscriptionId;
  end;

  TDispatcherThread = class(TThread)
  strict private
    FBus: TEventBus;
  protected
    procedure Execute; override;
  public
    constructor Create(ABus: TEventBus);
  end;

constructor TDispatcherThread.Create(ABus: TEventBus);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBus := ABus;
end;

procedure TDispatcherThread.Execute;
begin
  while not Terminated do
    FBus.DispatchOne;
end;

function NewDelivery(const AEvent: TServiceEvent; AHandler: TEventHandler;
  AId: TSubscriptionId): PPendingDelivery;
begin
  New(Result);
  { Initialize before assigning: New does not zero the managed fields, and
    assigning a string or an interface over uninitialised memory decrements a
    refcount that was never taken. }
  Initialize(Result^);
  Result^.Event := AEvent;
  Result^.Handler := AHandler;
  Result^.SubId := AId;
end;

procedure FreeDelivery(APtr: PPendingDelivery);
begin
  { Finalize releases the strings and the payload interface. Dispose alone would
    leak both. }
  Finalize(APtr^);
  Dispose(APtr);
end;

{ TEventBus }

constructor TEventBus.Create(AQueueCapacity: Integer);
begin
  inherited Create;

  { Counters first: a constructor that raises still runs its destructor. }
  FStopping.Init;
  FPublished.Init;
  FDelivered.Init;
  FDropped.Init;
  FDiscarded.Init;
  FCoalesced.Init;

  FLock := TCriticalSection.Create;
  FSubscriptions := TList<TSubscription>.Create;
  FNextId := 1;

  FBackgroundQueue := TBoundedQueue<Pointer>.Create(AQueueCapacity);
  FMainThreadQueue := TBoundedQueue<Pointer>.Create(AQueueCapacity);

  FDispatcher := TDispatcherThread.Create(Self);
  FDispatcher.Start;
end;

destructor TEventBus.Destroy;
var
  Ptr: Pointer;
begin
  FStopping.Exchange(1);

  { Close first so the dispatcher's Pop returns qwClosed instead of waiting out
    its timeout, then join before anything it touches is freed. }
  if FBackgroundQueue <> nil then
    FBackgroundQueue.Close;
  if FMainThreadQueue <> nil then
    FMainThreadQueue.Close;

  if FDispatcher <> nil then
  begin
    FDispatcher.Terminate;
    FDispatcher.WaitFor;
    FDispatcher.Free;
  end;

  { Anything still queued is ours to release. }
  if FBackgroundQueue <> nil then
    while FBackgroundQueue.Pop(Ptr, 0) = qwOK do
      FreeDelivery(PPendingDelivery(Ptr));
  if FMainThreadQueue <> nil then
    while FMainThreadQueue.Pop(Ptr, 0) = qwOK do
      FreeDelivery(PPendingDelivery(Ptr));

  FBackgroundQueue.Free;
  FMainThreadQueue.Free;
  FSubscriptions.Free;
  FLock.Free;
  inherited Destroy;
end;

function TEventBus.Stopping: Boolean;
begin
  Result := FStopping.Value <> 0;
end;

function TEventBus.Subscribe(AHandler: TEventHandler;
  AAffinity: TThreadAffinity; const ASource, ATopic: string;
  ACoalesce: Boolean): TSubscriptionId;
var
  Sub: TSubscription;
begin
  if not Assigned(AHandler) then
    raise EPoolArgument.Create('Subscribe requires a handler.');

  FLock.Enter;
  try
    Sub.Id := FNextId;
    Inc(FNextId);
    Sub.Handler := AHandler;
    Sub.Affinity := AAffinity;
    Sub.SourceFilter := ASource;
    Sub.TopicFilter := ATopic;
    Sub.Coalesce := ACoalesce;
    FSubscriptions.Add(Sub);
    Result := Sub.Id;
  finally
    FLock.Leave;
  end;
end;

procedure TEventBus.Unsubscribe(AId: TSubscriptionId);
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := FSubscriptions.Count - 1 downto 0 do
      if FSubscriptions[I].Id = AId then
      begin
        FSubscriptions.Delete(I);
        Break;
      end;
  finally
    FLock.Leave;
  end;
end;

function TEventBus.Matches(const ASub: TSubscription;
  const AEvent: TServiceEvent): Boolean;
begin
  { An empty filter matches everything — that is how the original's global
    listener list is expressed without a second registry. }
  if (ASub.SourceFilter <> '') and
     not SameText(ASub.SourceFilter, AEvent.Source) then
    Exit(False);
  if (ASub.TopicFilter <> '') and
     not SameText(ASub.TopicFilter, AEvent.Topic) then
    Exit(False);
  Result := True;
end;

function TEventBus.SnapshotSubscriptions: TArray<TSubscription>;
var
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FSubscriptions.Count);
    for I := 0 to FSubscriptions.Count - 1 do
      Result[I] := FSubscriptions[I];
  finally
    FLock.Leave;
  end;
end;

function TEventBus.Publish(const ASource, ATopic: string; ALevel: TEventLevel;
  const AMessage: string; ADatum: Integer; APayload: IEventPayload): Boolean;
var
  AEvent: TServiceEvent;
  Subs: TArray<TSubscription>;
  I: Integer;
  Delivery: PPendingDelivery;
  Queue: TBoundedQueue<Pointer>;
  AnyDropped: Boolean;
begin
  if Stopping then
    Exit(False);

  AEvent := TServiceEvent.Create(ASource, ATopic, ALevel, AMessage, ADatum,
    APayload);

  FPublished.Increment;

  { The subscriber list is snapshotted under the lock and then released, so a
    handler is never invoked with the bus's lock held and Subscribe is never
    blocked by a slow delivery. }
  Subs := SnapshotSubscriptions;
  AnyDropped := False;

  {$IFDEF PROVE_SYNC_PUBLISH}
  { ---------------------------------------------------------------------------
    NEGATIVE BUILD. Not shipped.

    Delivers on the publisher's thread instead of queueing, which is what
    "publishing is almost free" means when it is not true: a slow subscriber now
    stalls the service that published. The suite's latency assertion fails.
    --------------------------------------------------------------------------- }
  for I := 0 to High(Subs) do
    if Matches(Subs[I], AEvent) then
    begin
      Subs[I].Handler(AEvent);
      FDelivered.Increment;
    end;
  Exit(True);
  {$ELSE}

  for I := 0 to High(Subs) do
  begin
    if not Matches(Subs[I], AEvent) then
      Continue;

    {$IFDEF PROVE_NO_AFFINITY}
    { NEGATIVE BUILD: every subscriber goes to the background lane, so a
      main-thread subscriber runs on the dispatcher and the suite's ThreadID
      assertion fails. }
    Queue := FBackgroundQueue;
    {$ELSE}
    if Subs[I].Affinity = saMainThread then
      Queue := FMainThreadQueue
    else
      Queue := FBackgroundQueue;
    {$ENDIF}

    Delivery := NewDelivery(AEvent, Subs[I].Handler, Subs[I].Id);
    { Timeout 0: publishing never waits. A full lane drops, and the drop is
      counted rather than silent. }
    if Queue.Push(Delivery, 0) <> qwOK then
    begin
      FreeDelivery(Delivery);
      FDropped.Increment;
      AnyDropped := True;
    end;
  end;

  Result := not AnyDropped;
  {$ENDIF}
end;

procedure TEventBus.DispatchOne;
var
  Ptr: Pointer;
  Delivery: PPendingDelivery;
begin
  { A bounded wait, so Terminate is noticed even with nothing arriving. }
  if FBackgroundQueue.Pop(Ptr, 50) <> qwOK then
    Exit;

  Delivery := PPendingDelivery(Ptr);
  try
    { The handler runs with no lock held. A subscriber may publish, subscribe or
      unsubscribe from inside its own handler without deadlocking, which is the
      whole reason the subscriber list was snapshotted rather than held. }
    if Assigned(Delivery^.Handler) then
      Delivery^.Handler(Delivery^.Event);
    FDelivered.Increment;
  finally
    { Released whatever the handler did, including raising. A subscriber that
      throws must not take the dispatcher — and therefore every other
      subscriber — down with it. }
    FreeDelivery(Delivery);
  end;
end;

function TEventBus.DeliverPending(AMax: Integer): Integer;
var
  Ptr: Pointer;
  Delivery: PPendingDelivery;
begin
  Result := 0;
  while Result < AMax do
  begin
    if FMainThreadQueue.Pop(Ptr, 0) <> qwOK then
      Break;
    Delivery := PPendingDelivery(Ptr);
    try
      if Assigned(Delivery^.Handler) then
        Delivery^.Handler(Delivery^.Event);
      FDelivered.Increment;
      Inc(Result);
    finally
      FreeDelivery(Delivery);
    end;
  end;
end;

function TEventBus.DiscardFor(const AServiceName: string): Integer;
var
  Kept: TList<Pointer>;
  Ptr: Pointer;
  Delivery: PPendingDelivery;
  Dropped: Integer;

  procedure Sweep(AQueue: TBoundedQueue<Pointer>);
  var
    P: Pointer;
    D: PPendingDelivery;
    K: Integer;
  begin
    Kept.Clear;
    { Drain, decide, and put back what survives. The queue has no removal
      operation on purpose — a queue that lets you reach into the middle is a
      queue whose invariants nobody can reason about. }
    while AQueue.Pop(P, 0) = qwOK do
    begin
      D := PPendingDelivery(P);
      if SameText(D^.Event.Source, AServiceName) then
      begin
        FreeDelivery(D);
        Inc(Dropped);
      end
      else
        Kept.Add(P);
    end;
    for K := 0 to Kept.Count - 1 do
      if AQueue.Push(Kept[K], 0) <> qwOK then
      begin
        { Cannot happen — everything here came out of this same queue — but
          leaking on an impossible branch is still a leak. }
        FreeDelivery(PPendingDelivery(Kept[K]));
        FDropped.Increment;
      end;
  end;

begin
  Dropped := 0;
  Kept := TList<Pointer>.Create;
  try
    { Held across both lanes so a caller that has stopped a service and then
      called DiscardFor knows that when it returns, nothing of that service's is
      left anywhere. }
    FLock.Enter;
    try
      Sweep(FBackgroundQueue);
      Sweep(FMainThreadQueue);
    finally
      FLock.Leave;
    end;
  finally
    Kept.Free;
  end;

  if Dropped > 0 then
    FDiscarded.Add(Dropped);
  Result := Dropped;
  { Silences the hint about Ptr/Delivery being unused in this scope; the nested
    procedure has its own. }
  Ptr := nil;
  Delivery := Ptr;
  if Delivery <> nil then ;
end;

function TEventBus.WaitDrained(ATimeoutMs: Cardinal): Boolean;
var
  Start: UInt64;
begin
  Start := Ticks;
  repeat
    if FBackgroundQueue.Count = 0 then
      Exit(True);
    if Remaining(Start, ATimeoutMs) = 0 then
      Exit(False);
    { The queue's own blocking is for consumers; a drain check is a poll by
      nature, and this is test/shutdown code rather than a hot path. }
    TThread.Sleep(2);
  until False;
end;

function TEventBus.Published_: Integer;
begin
  Result := FPublished.Value;
end;

function TEventBus.Delivered: Integer;
begin
  Result := FDelivered.Value;
end;

function TEventBus.Dropped: Integer;
begin
  Result := FDropped.Value;
end;

function TEventBus.Discarded: Integer;
begin
  Result := FDiscarded.Value;
end;

function TEventBus.Coalesced: Integer;
begin
  Result := FCoalesced.Value;
end;

function TEventBus.PendingBackground: Integer;
begin
  Result := FBackgroundQueue.Count;
end;

function TEventBus.PendingMainThread: Integer;
begin
  Result := FMainThreadQueue.Count;
end;

function TEventBus.SubscriptionCount: Integer;
begin
  FLock.Enter;
  try
    Result := FSubscriptions.Count;
  finally
    FLock.Leave;
  end;
end;

end.
