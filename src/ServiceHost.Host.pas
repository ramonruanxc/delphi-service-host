{
  ServiceHost — the host.

  Owns the bus, owns one thread per service, and owns the order in which things
  start and stop. A service never sees the host and never sees another service.

  The stop sequence is the part worth reading, because it is where the design
  this was extracted from had two half-measures where one whole one was needed.
  That version checked at PUBLISH time whether the source service was stopping,
  and separately purged the queue when it stopped. Neither is sufficient alone,
  and together they still race: an event can pass the publish check, sit in the
  queue, and be delivered after the service is gone.

  Here stopping is one ordered sequence:

    1. cancel the token, so the loop stops before its next tick
    2. join the thread, so no further publish is possible from that service
    3. call DiscardFor, which retires every pending event of that service on
       both lanes and waits out a delivery of it already in progress

  After step 3 returns there is nothing left of that service anywhere, and the
  claim is total rather than probabilistic — which is what makes it testable.
}
unit ServiceHost.Host;

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
  ConcurrentPool.Worker,
  ServiceHost.Events,
  ServiceHost.Bus,
  ServiceHost.Service;

type
  TServiceHost = class
  strict private
    type
      TEntry = class
      public
        Service: IService;
        Worker: TWorker;
        State: TAtomicCounter;
        Ticks: TAtomicCounter;
        Faults: TAtomicCounter;
        constructor Create(const AService: IService);
      end;
  strict private
    FBus: TEventBus;
    FOwnsBus: Boolean;
    FLock: TCriticalSection;
    FEntries: TObjectList<TEntry>;
    function FindEntry(const AName: string): TEntry;
    procedure StopEntry(AEntry: TEntry; ATimeoutMs: Cardinal);
  public
    constructor Create(ABus: TEventBus = nil; AQueueCapacity: Integer = 1024);
    destructor Destroy; override;

    { The bus the host publishes through. Subscribe here. }
    function Bus: TEventBus;

    { Registering does not start anything. A duplicate name is rejected: a
      subscription filters on the name, so two services sharing one would make
      the filter meaningless.

      By value, deliberately, and NOT const. Register is written to be called
      with the service created inline:

        Host.Register(TTickerService.Create('poll', 500));

      A const interface parameter takes no reference. Written that way, a
      refused registration — a duplicate name — would leave a service that no
      reference ever counted, so nothing would free it. By value, the parameter
      itself owns a reference for the length of the call and gives it back on
      the way out, including while an exception is unwinding.

      PROVE_CONST_REGISTER restores the const and the leak gate catches it. }
    {$IFDEF PROVE_CONST_REGISTER}
    procedure Register(const AService: IService);
    {$ELSE}
    procedure Register(AService: IService);
    {$ENDIF}

    procedure Start(const AName: string);
    procedure StartAll;

    { Cancel, join, then discard that service's pending events — in that order.
      Returns False if the service did not stop within the timeout. }
    function Stop(const AName: string; ATimeoutMs: Cardinal = 5000): Boolean;
    function StopAll(ATimeoutMs: Cardinal = 5000): Boolean;

    { Blocks until every named service is running, or the timeout expires. The
      original's WaitForServicesToStart, kept because a service that publishes
      immediately needs its subscribers to exist first. }
    function WaitRunning(const ANames: array of string;
      ATimeoutMs: Cardinal = 3000): Boolean;

    function StateOf(const AName: string): TServiceState;
    function TickCountOf(const AName: string): Integer;
    function FaultCountOf(const AName: string): Integer;
    function Count: Integer;
    function Names: TArray<string>;
  end;

implementation

type
  { The loop. One per service, running on the worker's thread. }
  PAtomicCounter = ^TAtomicCounter;

  TServiceRunner = class(TInterfacedObject, IRunnable)
  strict private
    FService: IService;
    FBus: TEventBus;
    { Point at counters living in the host's entry, which is a heap object, so
      the addresses are stable for as long as the runner exists. }
    FState: PAtomicCounter;
    FTicks: PAtomicCounter;
    FFaults: PAtomicCounter;
  public
    constructor Create(const AService: IService; ABus: TEventBus;
      AState, ATicks, AFaults: PAtomicCounter);
    procedure Run(const AToken: ICancellationToken);
  end;

constructor TServiceRunner.Create(const AService: IService; ABus: TEventBus;
  AState, ATicks, AFaults: PAtomicCounter);
begin
  inherited Create;
  FService := AService;
  FBus := ABus;
  FState := AState;
  FTicks := ATicks;
  FFaults := AFaults;
end;

procedure TServiceRunner.Run(const AToken: ICancellationToken);
var
  Context: IServiceContext;
  Interval: Cardinal;
  LastTick: UInt64;
  Wait: Cardinal;
  Gone: Cardinal;
begin
  { Built HERE, from the token Run was handed. The host cannot build it earlier:
    TWorker needs its runnable at construction and the context needs the
    worker's token, so anything assembled outside would be a chicken and egg.
    Inside Run both exist, and the context is scoped to exactly the run it
    belongs to. }
  Context := MakeContext(FService.Name, FBus, AToken);
  FState^.Exchange(Ord(svStarting));
  try
    FService.Starting(Context);
  except
    on E: Exception do
    begin
      FFaults^.Increment;
      FState^.Exchange(Ord(svFaulted));
      Context.Fail('service.start', E.Message);
      Exit;
    end;
  end;

  FState^.Exchange(Ord(svRunning));
  Interval := Cardinal(FService.Interval);
  { Ticks immediately on start, then on the interval. }
  LastTick := 0;

  while not AToken.IsCancelled do
  begin
    if LastTick <> 0 then
    begin
      Gone := Elapsed(LastTick);
      if Gone < Interval then
      begin
        Wait := Interval - Gone;
        { WAITS, does not spin. The original polled with Sleep(1), waking a
          thousand times a second per service to almost always do nothing. This
          sleeps for the whole remaining interval and is woken early by
          cancellation, so a service costs nothing between ticks and still stops
          at once. }
        if AToken.WaitCancelled(Wait) then
          Break;
        Continue;
      end;
    end;

    LastTick := ConcurrentPool.Types.Ticks;
    try
      FService.Tick(Context);
      FTicks^.Increment;
    except
      on E: Exception do
      begin
        { A tick that throws must not end the service. The original logged and
          carried on too; the difference is that the fault is counted here, so
          "it is running but every tick fails" is visible rather than buried in
          a log. }
        FFaults^.Increment;
        Context.Fail('service.tick', E.Message);
      end;
    end;
  end;

  FState^.Exchange(Ord(svStopping));
  try
    FService.Stopped;
  except
    on E: Exception do
      FFaults^.Increment;
  end;
  FState^.Exchange(Ord(svStopped));
end;

{ TServiceHost.TEntry }

constructor TServiceHost.TEntry.Create(const AService: IService);
begin
  inherited Create;
  Service := AService;
  State.Init(Ord(svStopped));
  Ticks.Init;
  Faults.Init;
end;

{ TServiceHost }

constructor TServiceHost.Create(ABus: TEventBus; AQueueCapacity: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TObjectList<TEntry>.Create(True);
  FOwnsBus := ABus = nil;
  if FOwnsBus then
    FBus := TEventBus.Create(AQueueCapacity)
  else
    FBus := ABus;
end;

destructor TServiceHost.Destroy;
begin
  if FEntries <> nil then
    StopAll(WAIT_INFINITE);
  FEntries.Free;
  if FOwnsBus then
    FBus.Free;
  FLock.Free;
  inherited Destroy;
end;

function TServiceHost.Bus: TEventBus;
begin
  Result := FBus;
end;

function TServiceHost.FindEntry(const AName: string): TEntry;
var
  I: Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    if SameText(FEntries[I].Service.Name, AName) then
      Exit(FEntries[I]);
  Result := nil;
end;

{$IFDEF PROVE_CONST_REGISTER}
procedure TServiceHost.Register(const AService: IService);
{$ELSE}
procedure TServiceHost.Register(AService: IService);
{$ENDIF}
begin
  if AService = nil then
    raise EPoolArgument.Create('Register requires a service.');

  FLock.Enter;
  try
    if FindEntry(AService.Name) <> nil then
      raise EPoolArgument.CreateFmt(
        'A service named "%s" is already registered. Names must be unique, ' +
        'because subscriptions filter on them.', [AService.Name]);
    FEntries.Add(TEntry.Create(AService));
  finally
    FLock.Leave;
  end;
end;

procedure TServiceHost.Start(const AName: string);
var
  Entry: TEntry;
  Runner: IRunnable;
begin
  FLock.Enter;
  try
    Entry := FindEntry(AName);
    if Entry = nil then
      raise EPoolArgument.CreateFmt('No service named "%s".', [AName]);
    if Entry.Worker <> nil then
      raise EPoolState.CreateFmt('Service "%s" is already started.', [AName]);

    { The worker is created first so its token exists, then the context is built
      around that token, then the runner around both. }
    Runner := TServiceRunner.Create(Entry.Service, FBus,
      @Entry.State, @Entry.Ticks, @Entry.Faults);
    Entry.Worker := TWorker.Create(Runner);
    try
      Entry.Worker.Start;
    except
      Entry.Worker.Free;
      Entry.Worker := nil;
      raise;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TServiceHost.StartAll;
var
  I: Integer;
  ToStart: TArray<string>;
begin
  FLock.Enter;
  try
    SetLength(ToStart, FEntries.Count);
    for I := 0 to FEntries.Count - 1 do
      ToStart[I] := FEntries[I].Service.Name;
  finally
    FLock.Leave;
  end;

  for I := 0 to High(ToStart) do
    Start(ToStart[I]);
end;

procedure TServiceHost.StopEntry(AEntry: TEntry; ATimeoutMs: Cardinal);
begin
  if AEntry.Worker = nil then
    Exit;

  { 1. cancel — the loop leaves before its next tick }
  AEntry.Worker.Cancel;
  { 2. join — after this the service cannot publish again }
  AEntry.Worker.WaitFor(ATimeoutMs);
  AEntry.Worker.Free;
  AEntry.Worker := nil;
  {$IFDEF PROVE_NO_DISCARD}
  { ---------------------------------------------------------------------------
    NEGATIVE BUILD. Not shipped.

    Skips step 3. Cancel and join alone look sufficient — the service is not
    running and cannot publish again — but events it published BEFORE the stop
    are still sitting on the dispatcher lanes, and they arrive afterwards. A
    subscriber then hears from a service the host reports as stopped, which is
    the whole difference between "stopped" and "stopped and settled". The
    suite's "nothing from the stopped service arrives afterwards" fails.
    --------------------------------------------------------------------------- }
  {$ELSE}
  { 3. discard — nothing of this service is left pending on either lane }
  FBus.DiscardFor(AEntry.Service.Name, ATimeoutMs);
  {$ENDIF}
end;

function TServiceHost.Stop(const AName: string; ATimeoutMs: Cardinal): Boolean;
var
  Entry: TEntry;
begin
  FLock.Enter;
  try
    Entry := FindEntry(AName);
    if Entry = nil then
      raise EPoolArgument.CreateFmt('No service named "%s".', [AName]);
    StopEntry(Entry, ATimeoutMs);
    Result := TServiceState(Entry.State.Value) = svStopped;
  finally
    FLock.Leave;
  end;
end;

function TServiceHost.StopAll(ATimeoutMs: Cardinal): Boolean;
var
  I: Integer;
begin
  Result := True;
  FLock.Enter;
  try
    for I := 0 to FEntries.Count - 1 do
    begin
      StopEntry(FEntries[I], ATimeoutMs);
      if TServiceState(FEntries[I].State.Value) <> svStopped then
        Result := False;
    end;
  finally
    FLock.Leave;
  end;
end;

function TServiceHost.WaitRunning(const ANames: array of string;
  ATimeoutMs: Cardinal): Boolean;
var
  Start: UInt64;
  I: Integer;
  AllUp: Boolean;
begin
  Start := ConcurrentPool.Types.Ticks;
  repeat
    AllUp := True;
    for I := Low(ANames) to High(ANames) do
      if StateOf(ANames[I]) <> svRunning then
      begin
        AllUp := False;
        Break;
      end;
    if AllUp then
      Exit(True);
    if Remaining(Start, ATimeoutMs) = 0 then
      Exit(False);
    TThread.Sleep(2);
  until False;
end;

function TServiceHost.StateOf(const AName: string): TServiceState;
var
  Entry: TEntry;
begin
  FLock.Enter;
  try
    Entry := FindEntry(AName);
    if Entry = nil then
      Exit(svStopped);
    Result := TServiceState(Entry.State.Value);
  finally
    FLock.Leave;
  end;
end;

function TServiceHost.TickCountOf(const AName: string): Integer;
var
  Entry: TEntry;
begin
  FLock.Enter;
  try
    Entry := FindEntry(AName);
    if Entry = nil then
      Exit(0);
    Result := Entry.Ticks.Value;
  finally
    FLock.Leave;
  end;
end;

function TServiceHost.FaultCountOf(const AName: string): Integer;
var
  Entry: TEntry;
begin
  FLock.Enter;
  try
    Entry := FindEntry(AName);
    if Entry = nil then
      Exit(0);
    Result := Entry.Faults.Value;
  finally
    FLock.Leave;
  end;
end;

function TServiceHost.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FEntries.Count;
  finally
    FLock.Leave;
  end;
end;

function TServiceHost.Names: TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FEntries.Count);
    for I := 0 to FEntries.Count - 1 do
      Result[I] := FEntries[I].Service.Name;
  finally
    FLock.Leave;
  end;
end;

end.
