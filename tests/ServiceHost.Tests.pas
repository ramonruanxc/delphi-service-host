{
  ServiceHost — the suite.

  What is under test is the COMMUNICATION, because that is the whole point of a
  service host: services that each run in their own thread and can only reach
  one another through the bus.

  Every wait is bounded. No test waits on WAIT_INFINITE.
}
unit ServiceHost.Tests;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  ServiceHost.Testing;

procedure RunTests(ARunner: TTestRunner);

implementation

uses
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs{$ENDIF},
  ConcurrentPool.Types,
  ConcurrentPool.Atomic,
  ServiceHost.Events,
  ServiceHost.Bus,
  ServiceHost.Service,
  ServiceHost.Host;

const
  BLOCK_MS = 5000;
  SETTLE_MS = 250;

type
  { Records what it was handed, and on which thread. }
  TRecorder = class
  strict private
    FLock: TCriticalSection;
    FEvents: TArray<TServiceEvent>;
    FThreadIds: TArray<TThreadID>;
    FSlowMs: Integer;
  public
    constructor Create(ASlowMs: Integer = 0);
    destructor Destroy; override;
    procedure Handle(const AEvent: TServiceEvent);
    function Count: Integer;
    function EventAt(AIndex: Integer): TServiceEvent;
    function ThreadIdAt(AIndex: Integer): TThreadID;
    function AllFromSource(const ASource: string): Boolean;
    function AnyFromSource(const ASource: string): Boolean;
  end;

  { Publishes a counter on every tick. }
  TTickerService = class(TBaseService)
  strict private
    FCount: Integer;
  public
    procedure Tick(const AContext: IServiceContext); override;
  end;

  { Publishes once on Starting and never again — for testing lifecycle order. }
  TAnnouncerService = class(TBaseService)
  strict private
    FStartedFlag: TAtomicCounter;
    FStoppedFlag: TAtomicCounter;
  public
    constructor Create(const AName: string; AIntervalMs: Integer);
    procedure Starting(const AContext: IServiceContext); override;
    procedure Stopped; override;
    procedure Tick(const AContext: IServiceContext); override;
    function DidStart: Boolean;
    function DidStop: Boolean;
  end;

  { Throws on every tick. The host must keep it running and count the faults. }
  TFaultingService = class(TBaseService)
  public
    procedure Tick(const AContext: IServiceContext); override;
  end;

  { Publishes a burst per tick, to fill a small bus. }
  TBurstService = class(TBaseService)
  strict private
    FPerTick: Integer;
  public
    constructor Create(const AName: string; AIntervalMs, APerTick: Integer);
    procedure Tick(const AContext: IServiceContext); override;
  end;

  { Counts how many payload objects are alive, so payload ownership across N
    subscribers can be asserted rather than assumed. }
  TCountedPayload = class(TInterfacedObject, IEventPayload)
  public
    constructor Create;
    destructor Destroy; override;
    function Describe: string;
  end;

  { Subscribes to ANOTHER service's events and republishes a reaction. This is
    the entire reason a bus exists: two threads that never touch, cooperating.
    A service is both a publisher and, through an ordinary handler, a
    subscriber. }
  TReactorService = class(TBaseService)
  strict private
    FHeard: TAtomicCounter;
    FPending: TAtomicCounter;
  public
    constructor Create(const AName: string; AIntervalMs: Integer);
    procedure Tick(const AContext: IServiceContext); override;
    procedure OnHeard(const AEvent: TServiceEvent);
    function Heard: Integer;
  end;

var
  GPayloadsAlive: TAtomicCounter;

{ ------------------------------------------------------------- fixtures }

constructor TRecorder.Create(ASlowMs: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSlowMs := ASlowMs;
end;

destructor TRecorder.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TRecorder.Handle(const AEvent: TServiceEvent);
begin
  if FSlowMs > 0 then
    TThread.Sleep(FSlowMs);
  FLock.Enter;
  try
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := AEvent;
    SetLength(FThreadIds, Length(FThreadIds) + 1);
    FThreadIds[High(FThreadIds)] := TThread.CurrentThread.ThreadID;
  finally
    FLock.Leave;
  end;
end;

function TRecorder.Count: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FEvents);
  finally
    FLock.Leave;
  end;
end;

function TRecorder.EventAt(AIndex: Integer): TServiceEvent;
begin
  FLock.Enter;
  try
    Result := FEvents[AIndex];
  finally
    FLock.Leave;
  end;
end;

function TRecorder.ThreadIdAt(AIndex: Integer): TThreadID;
begin
  FLock.Enter;
  try
    Result := FThreadIds[AIndex];
  finally
    FLock.Leave;
  end;
end;

function TRecorder.AllFromSource(const ASource: string): Boolean;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FEvents) do
      if not SameText(FEvents[I].Source, ASource) then
        Exit(False);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TRecorder.AnyFromSource(const ASource: string): Boolean;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FEvents) do
      if SameText(FEvents[I].Source, ASource) then
        Exit(True);
    Result := False;
  finally
    FLock.Leave;
  end;
end;

procedure TTickerService.Tick(const AContext: IServiceContext);
begin
  Inc(FCount);
  AContext.Info('tick', 'tick ' + IntToStr(FCount), FCount);
end;

constructor TAnnouncerService.Create(const AName: string; AIntervalMs: Integer);
begin
  inherited Create(AName, AIntervalMs);
  FStartedFlag.Init;
  FStoppedFlag.Init;
end;

procedure TAnnouncerService.Starting(const AContext: IServiceContext);
begin
  FStartedFlag.Exchange(1);
  AContext.Info('lifecycle', 'starting', 0);
end;

procedure TAnnouncerService.Stopped;
begin
  FStoppedFlag.Exchange(1);
end;

procedure TAnnouncerService.Tick(const AContext: IServiceContext);
begin
  { Nothing: this one only reports its lifecycle. }
end;

function TAnnouncerService.DidStart: Boolean;
begin
  Result := FStartedFlag.Value <> 0;
end;

function TAnnouncerService.DidStop: Boolean;
begin
  Result := FStoppedFlag.Value <> 0;
end;

procedure TFaultingService.Tick(const AContext: IServiceContext);
begin
  raise Exception.Create('this tick always fails');
end;

constructor TBurstService.Create(const AName: string; AIntervalMs, APerTick: Integer);
begin
  inherited Create(AName, AIntervalMs);
  FPerTick := APerTick;
end;

procedure TBurstService.Tick(const AContext: IServiceContext);
var
  I: Integer;
begin
  for I := 1 to FPerTick do
    AContext.Info('burst', '', I);
end;

constructor TCountedPayload.Create;
begin
  inherited Create;
  GPayloadsAlive.Increment;
end;

destructor TCountedPayload.Destroy;
begin
  GPayloadsAlive.Decrement;
  inherited Destroy;
end;

function TCountedPayload.Describe: string;
begin
  Result := 'counted';
end;

constructor TReactorService.Create(const AName: string; AIntervalMs: Integer);
begin
  inherited Create(AName, AIntervalMs);
  FHeard.Init;
  FPending.Init;
end;

procedure TReactorService.OnHeard(const AEvent: TServiceEvent);
begin
  { Runs on the bus's dispatcher thread, NOT on this service's thread. So it
    only records; the reaction is published from Tick, on the service's own
    thread, where the service owns its state. }
  FHeard.Increment;
  FPending.Increment;
end;

procedure TReactorService.Tick(const AContext: IServiceContext);
var
  Owed: Integer;
begin
  Owed := FPending.Exchange(0);
  if Owed > 0 then
    AContext.Info('reacted', 'reacting to ' + IntToStr(Owed) + ' ticks', Owed);
end;

function TReactorService.Heard: Integer;
begin
  Result := FHeard.Value;
end;

{ =================================================== 1. routing and filters }

procedure TestRouting(R: TTestRunner);
var
  Bus: TEventBus;
  All, OnlyA, OnlyTopic: TRecorder;
begin
  R.Suite('Bus — subscriptions route by source and topic');

  Bus := TEventBus.Create(256);
  All := TRecorder.Create;
  OnlyA := TRecorder.Create;
  OnlyTopic := TRecorder.Create;
  try
    { An empty source filter is how "listen to everything" is expressed — the
      original kept a second, global registry for this; one filter covers both. }
    Bus.Subscribe(All.Handle, saBackground, '', '');
    Bus.Subscribe(OnlyA.Handle, saBackground, 'svcA', '');
    Bus.Subscribe(OnlyTopic.Handle, saBackground, '', 'interesting');

    Bus.Publish('svcA', 'interesting', elInfo, 'a1', 1, nil);
    Bus.Publish('svcB', 'boring', elInfo, 'b1', 2, nil);
    Bus.Publish('svcA', 'boring', elInfo, 'a2', 3, nil);

    R.Begins('waiting for the bus to drain');
    R.IsTrue('the bus drains', Bus.WaitDrained(BLOCK_MS));

    R.AreEqual('a global subscriber sees every event', 3, All.Count);
    R.AreEqual('a source-filtered subscriber sees only that service', 2, OnlyA.Count);
    R.IsTrue('  and every one of them is from that service',
      OnlyA.AllFromSource('svcA'));
    R.AreEqual('a topic-filtered subscriber sees only that topic', 1, OnlyTopic.Count);
    R.AreEqual('  and it is the right one', 'interesting',
      OnlyTopic.EventAt(0).Topic);

    R.AreEqual('published counts events, not deliveries', 3, Bus.Published_);
    R.AreEqual('delivered counts deliveries', 6, Bus.Delivered);
    R.AreEqual('nothing dropped', 0, Bus.Dropped);
  finally
    Bus.Free;
    All.Free;
    OnlyA.Free;
    OnlyTopic.Free;
  end;
end;

procedure TestUnsubscribe(R: TTestRunner);
var
  Bus: TEventBus;
  Rec: TRecorder;
  Id: TSubscriptionId;
begin
  R.Suite('Bus — unsubscribing');

  Bus := TEventBus.Create(64);
  Rec := TRecorder.Create;
  try
    Id := Bus.Subscribe(Rec.Handle, saBackground);
    R.AreEqual('one subscription', 1, Bus.SubscriptionCount);
    Bus.Publish('s', 't', elInfo, '', 1, nil);
    Bus.WaitDrained(BLOCK_MS);
    R.AreEqual('it received', 1, Rec.Count);

    Bus.Unsubscribe(Id);
    R.AreEqual('no subscriptions left', 0, Bus.SubscriptionCount);
    Bus.Publish('s', 't', elInfo, '', 2, nil);
    Bus.WaitDrained(BLOCK_MS);
    R.AreEqual('and it receives nothing more', 1, Rec.Count);
  finally
    Bus.Free;
    Rec.Free;
  end;
end;

{ ========================================================== 2. thread affinity }

procedure TestAffinity(R: TTestRunner);
var
  Bus: TEventBus;
  Background, MainOnly: TRecorder;
  MainId: TThreadID;
  Delivered: Integer;
begin
  R.Suite('Bus — main-thread affinity');

  MainId := TThread.CurrentThread.ThreadID;
  Bus := TEventBus.Create(64);
  Background := TRecorder.Create;
  MainOnly := TRecorder.Create;
  try
    Bus.Subscribe(Background.Handle, saBackground);
    Bus.Subscribe(MainOnly.Handle, saMainThread);

    Bus.Publish('s', 'topic', elInfo, 'x', 7, nil);
    R.Begins('background delivery');
    R.IsTrue('the background lane drains on its own', Bus.WaitDrained(BLOCK_MS));
    R.AreEqual('the background subscriber received', 1, Background.Count);
    R.IsTrue('  on a thread that is NOT the main one',
      Background.ThreadIdAt(0) <> MainId);

    { The main-thread subscriber has NOT run yet, and that is the point: nothing
      delivers to it until the application pumps. }
    R.AreEqual('the main-thread subscriber has not run yet', 0, MainOnly.Count);
    R.AreEqual('  and its event is waiting', 1, Bus.PendingMainThread);

    Delivered := Bus.DeliverPending;
    R.AreEqual('DeliverPending delivers it', 1, Delivered);
    R.AreEqual('the main-thread subscriber received', 1, MainOnly.Count);
    { PROVE_NO_AFFINITY fails exactly here. }
    R.IsTrue('  on the thread that called DeliverPending',
      MainOnly.ThreadIdAt(0) = MainId);
  finally
    Bus.Free;
    Background.Free;
    MainOnly.Free;
  end;
end;

{ ================================================ 3. publishing does not block }

procedure TestPublishDoesNotBlock(R: TTestRunner);
const
  SLOW_MS = 120;
  EVENTS = 10;
var
  Bus: TEventBus;
  Slow: TRecorder;
  I: Integer;
  T0: UInt64;
  Took: Cardinal;
begin
  R.Suite('Bus — publishing never waits on a subscriber');

  Bus := TEventBus.Create(256);
  { Each delivery costs 120 ms. Delivered synchronously that is 1.2 s of the
    publisher's time; queued it is nothing. }
  Slow := TRecorder.Create(SLOW_MS);
  try
    Bus.Subscribe(Slow.Handle, saBackground);

    R.Begins('publishing ten events to a slow subscriber');
    T0 := Ticks;
    for I := 1 to EVENTS do
      Bus.Publish('s', 't', elInfo, '', I, nil);
    Took := Elapsed(T0);

    { PROVE_SYNC_PUBLISH fails here: delivering on the publisher's thread makes
      this take EVENTS * SLOW_MS instead of almost nothing. }
    R.IsTrue('the publisher returns immediately (' + IntToStr(Took) +
      ' ms for ' + IntToStr(EVENTS) + ' events)', Took < (SLOW_MS * 2));

    R.Begins('waiting for the slow subscriber to catch up');
    R.IsTrue('and the events still all arrive', Bus.WaitDrained(BLOCK_MS * 2));
    { WaitDrained returns when the queue is empty, which is a moment before the
      last handler returns. }
    TThread.Sleep(SLOW_MS * 2);
    R.AreEqual('every one of them', EVENTS, Slow.Count);
  finally
    Bus.Free;
    Slow.Free;
  end;
end;

procedure TestDropsWhenFull(R: TTestRunner);
var
  Bus: TEventBus;
  Slow: TRecorder;
  I: Integer;
begin
  R.Suite('Bus — a full lane drops, visibly');

  { Deliberately tiny, with a slow subscriber, so the lane fills. }
  Bus := TEventBus.Create(4);
  Slow := TRecorder.Create(30);
  try
    Bus.Subscribe(Slow.Handle, saBackground);
    R.Begins('flooding a tiny bus');
    for I := 1 to 200 do
      Bus.Publish('s', 't', elInfo, '', I, nil);

    R.AreEqual('everything was published', 200, Bus.Published_);
    R.IsTrue('and some of it was dropped rather than blocking the publisher',
      Bus.Dropped > 0);
    R.IsTrue('the accounting adds up',
      Bus.Delivered + Bus.Dropped + Bus.PendingBackground <= 200);
  finally
    Bus.Free;
    Slow.Free;
  end;
end;

{ ======================================================= 4. payload ownership }

{ The body lives in its own routine, and that is not tidiness.

  A managed temporary — here the TServiceEvent that EventAt returns by value,
  carrying an interface — is finalised when the routine that produced it EXITS,
  not when its statement ends. Measured on FPC 3.2.2: a refcount read many
  statements later, but still inside the same routine, counts the temporary;
  the same read after that routine returns does not.

  So a "is it freed yet?" assertion written at the bottom of this routine would
  be answering "does anyone hold it, other than this stack frame?" — which is
  not the question. Reading it from the caller is what makes the answer mean
  what the assertion says it means. }
procedure PayloadOwnershipBody(R: TTestRunner);
var
  Bus: TEventBus;
  A, B, C: TRecorder;
  Payload: IEventPayload;
begin
  Bus := TEventBus.Create(64);
  A := TRecorder.Create;
  B := TRecorder.Create;
  C := TRecorder.Create;
  try
    Bus.Subscribe(A.Handle, saBackground);
    Bus.Subscribe(B.Handle, saBackground);
    Bus.Subscribe(C.Handle, saBackground);

    { The design this was extracted from handed the same raw Pointer to all
      three. Whoever freed it first left the others reading freed memory; if
      nobody did, it leaked. Refcounting removes the question. }
    Payload := TCountedPayload.Create;
    R.AreEqual('one payload alive after creating it', 1, GPayloadsAlive.Value);

    Bus.Publish('s', 't', elSuccess, '', 0, Payload);
    Payload := nil;   { the publisher lets go immediately }

    R.Begins('draining three deliveries of one payload');
    R.IsTrue('the bus drains', Bus.WaitDrained(BLOCK_MS));
    TThread.Sleep(SETTLE_MS);

    R.AreEqual('all three subscribers got it', 3,
      A.Count + B.Count + C.Count);
    R.IsTrue('each still had a live payload when handling',
      (A.EventAt(0).Payload <> nil) and (B.EventAt(0).Payload <> nil));

    { The recorders still hold their copies, so it is still alive — which is
      itself the guarantee. }
    R.AreEqual('still alive while a subscriber holds it', 1,
      GPayloadsAlive.Value);
  finally
    Bus.Free;
    A.Free;
    B.Free;
    C.Free;
  end;
end;

procedure TestPayloadOwnership(R: TTestRunner);
begin
  R.Suite('Bus — one payload, three subscribers, no ambiguity');

  GPayloadsAlive.Exchange(0);
  PayloadOwnershipBody(R);

  { Read from out here, where no temporary of ours is still in scope: the bus is
    gone, every subscriber is gone, and nothing counted the payload on the way
    out. Nobody was appointed its owner and nobody had to be. }
  R.AreEqual('freed once the last holder let go, by nobody in particular', 0,
    GPayloadsAlive.Value);
end;

{ ============================================== 5. services and the lifecycle }

procedure TestServiceLifecycle(R: TTestRunner);
var
  Host: TServiceHost;
  Announcer: TAnnouncerService;
  Svc: IService;
  Rec: TRecorder;
begin
  R.Suite('Host — a service starts, ticks and stops');

  Host := TServiceHost.Create;
  Rec := TRecorder.Create;
  try
    Announcer := TAnnouncerService.Create('announcer', 20);
    Svc := Announcer;
    Host.Register(Svc);
    Host.Register(TTickerService.Create('ticker', 20));

    R.AreEqual('two services registered', 2, Host.Count);
    R.AreEqual('and both start stopped', Ord(svStopped),
      Ord(Host.StateOf('ticker')));

    Host.Bus.Subscribe(Rec.Handle, saBackground);
    Host.StartAll;

    R.Begins('waiting for both services to reach running');
    R.IsTrue('WaitRunning returns once they are up',
      Host.WaitRunning(['ticker', 'announcer'], BLOCK_MS));
    R.AreEqual('the ticker is running', Ord(svRunning),
      Ord(Host.StateOf('ticker')));

    R.Begins('letting the ticker tick');
    TThread.Sleep(SETTLE_MS);
    R.IsTrue('it ticked more than once', Host.TickCountOf('ticker') > 1);
    R.IsTrue('Starting ran before any tick', Announcer.DidStart);

    R.Begins('stopping everything');
    R.IsTrue('StopAll returns cleanly', Host.StopAll(BLOCK_MS));
    R.AreEqual('the ticker is stopped', Ord(svStopped),
      Ord(Host.StateOf('ticker')));
    R.IsTrue('Stopped ran', Announcer.DidStop);
    R.IsTrue('and the subscriber heard from them', Rec.Count > 0);
  finally
    Host.Free;
    Rec.Free;
  end;
end;

procedure TestFaultingServiceKeepsRunning(R: TTestRunner);
var
  Host: TServiceHost;
begin
  R.Suite('Host — a tick that throws does not kill the service');

  Host := TServiceHost.Create;
  try
    Host.Register(TFaultingService.Create('faulty', 10));
    Host.StartAll;
    R.IsTrue('it reaches running', Host.WaitRunning(['faulty'], BLOCK_MS));

    R.Begins('letting it fail repeatedly');
    TThread.Sleep(SETTLE_MS);

    R.IsTrue('the faults are counted', Host.FaultCountOf('faulty') > 1);
    R.AreEqual('and it is still running', Ord(svRunning),
      Ord(Host.StateOf('faulty')));
    R.IsTrue('it stops cleanly anyway', Host.StopAll(BLOCK_MS));
  finally
    Host.Free;
  end;
end;

procedure TestDuplicateNameRejected(R: TTestRunner);
var
  Host: TServiceHost;
  Raised: Boolean;
begin
  R.Suite('Host — names must be unique');

  Host := TServiceHost.Create;
  try
    Host.Register(TTickerService.Create('same', 50));
    Raised := False;
    try
      Host.Register(TTickerService.Create('same', 50));
    except
      on E: EPoolArgument do
        Raised := True;
    end;
    { A subscription filters on the name; two services sharing one would make
      the filter meaningless. }
    R.IsTrue('a duplicate name is refused', Raised);
    R.AreEqual('and only the first is registered', 1, Host.Count);
  finally
    Host.Free;
  end;
end;

{ ================================== 6. stopping discards a service's backlog }

procedure TestDiscardOnStop(R: TTestRunner);
var
  Host: TServiceHost;
  Slow: TRecorder;
begin
  R.Suite('Host — stopping a service discards its pending events');

  Host := TServiceHost.Create(nil, 4096);
  { Slow enough that a backlog builds while the burst service runs. }
  Slow := TRecorder.Create(5);
  try
    Host.Bus.Subscribe(Slow.Handle, saBackground);
    Host.Register(TBurstService.Create('burst', 1, 50));
    Host.Register(TTickerService.Create('quiet', 40));
    Host.StartAll;
    R.IsTrue('both are running',
      Host.WaitRunning(['burst', 'quiet'], BLOCK_MS));

    R.Begins('letting a backlog build');
    TThread.Sleep(SETTLE_MS);
    R.IsTrue('a backlog exists', Host.Bus.PendingBackground > 0);

    R.Begins('stopping the noisy service');
    R.IsTrue('it stops', Host.Stop('burst', BLOCK_MS));

    { Cancel, join, discard — in that order — so once Stop returns there is
      nothing of that service left anywhere. The original checked at publish
      time AND purged on stop, and still raced. }
    R.IsTrue('its events were discarded', Host.Bus.Discarded > 0);

    R.Begins('draining what is left');
    Host.Bus.WaitDrained(BLOCK_MS);
    TThread.Sleep(SETTLE_MS);

    { PROVE_NO_DISCARD fails here: without the purge, events published before
      the stop keep arriving after it. }
    R.IsTrue('nothing from the stopped service arrives afterwards',
      Host.Bus.Discarded > 0);

    R.IsTrue('the other service is unaffected and still running',
      Host.StateOf('quiet') = svRunning);
    Host.StopAll(BLOCK_MS);
  finally
    Host.Free;
    Slow.Free;
  end;
end;

{ ============================ 7. services talking to each other, which is why }

procedure TestServicesTalkToEachOther(R: TTestRunner);
var
  Host: TServiceHost;
  Reactor: TReactorService;
  Svc: IService;
  Watcher: TRecorder;
begin
  R.Suite('Host — one service reacts to another');

  Host := TServiceHost.Create;
  Watcher := TRecorder.Create;
  try
    Reactor := TReactorService.Create('reactor', 10);
    Svc := Reactor;
    Host.Register(TTickerService.Create('ticker', 10));
    Host.Register(Svc);

    { The reactor listens only to the ticker. }
    Host.Bus.Subscribe(Reactor.OnHeard, saBackground, 'ticker', 'tick');
    { And a watcher listens only to the reactor's reaction. }
    Host.Bus.Subscribe(Watcher.Handle, saBackground, 'reactor', 'reacted');

    Host.StartAll;
    R.IsTrue('both are running',
      Host.WaitRunning(['ticker', 'reactor'], BLOCK_MS));

    R.Begins('letting them talk');
    TThread.Sleep(SETTLE_MS * 2);
    Host.StopAll(BLOCK_MS);
    Host.Bus.WaitDrained(BLOCK_MS);
    TThread.Sleep(SETTLE_MS);

    R.IsTrue('the reactor heard the ticker', Reactor.Heard > 0);
    R.IsTrue('and its own reaction reached a third party', Watcher.Count > 0);
    R.IsTrue('  which only ever saw the reactor',
      Watcher.AllFromSource('reactor'));
  finally
    Host.Free;
    Watcher.Free;
  end;
end;

{ ==================================================================== entry }

procedure RunTests(ARunner: TTestRunner);
begin
  GPayloadsAlive.Init;

  TestRouting(ARunner);
  TestUnsubscribe(ARunner);
  TestAffinity(ARunner);
  TestPublishDoesNotBlock(ARunner);
  TestDropsWhenFull(ARunner);
  TestPayloadOwnership(ARunner);
  TestServiceLifecycle(ARunner);
  TestFaultingServiceKeepsRunning(ARunner);
  TestDuplicateNameRejected(ARunner);
  TestDiscardOnStop(ARunner);
  TestServicesTalkToEachOther(ARunner);
end;

end.
