{
  Three services running at once, each on its own thread, none of them holding a
  reference to any other. Everything they know about each other, they learned
  from an event.

    poller    every 120 ms, reports a queue depth that drifts up and down
    watchdog  subscribes to the poller; when the depth crosses a threshold it
              says so — it has never heard of TPollerService
    ticker    every 400 ms, publishes a heartbeat nobody subscribes to

  Plus one subscriber that is not a service at all:

    archivist a plain object that hears everything and tallies it per source

  Then the poller is stopped mid-flight, and the archivist's tally shows that
  nothing of the poller arrived after Stop returned. (The test suite proves the
  same guarantee against a real backlog, with a deliberately slow subscriber.)

  Needs no project options, search paths or defines on either compiler.

  Delphi (XE7 or later): open this file in the IDE and press F9. The uses
  clause carries every unit's path, relative to this file.

  Free Pascal, from the repository root:
    fpc demo/Newsroom.dpr
  The UNITPATH directives below stand in for -Fu, relative to this file.

  Ends with "Newsroom: OK" and exit code 0, or "Newsroom: FAILED" and 1.
}
program Newsroom;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
  {$UNITPATH ../src}
  {$UNITPATH ../lib/concurrent-pool}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IF DEFINED(FPC) AND DEFINED(UNIX)}
  cthreads,
  {$IFEND}
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}System.SysUtils, System.Classes,
    System.SyncObjs{$ENDIF},
  ConcurrentPool.Types in '../lib/concurrent-pool/ConcurrentPool.Types.pas',
  ConcurrentPool.Atomic in '../lib/concurrent-pool/ConcurrentPool.Atomic.pas',
  ConcurrentPool.Queue in '../lib/concurrent-pool/ConcurrentPool.Queue.pas',
  ConcurrentPool.Worker in '../lib/concurrent-pool/ConcurrentPool.Worker.pas',
  ServiceHost.Events in '../src/ServiceHost.Events.pas',
  ServiceHost.Bus in '../src/ServiceHost.Bus.pas',
  ServiceHost.Service in '../src/ServiceHost.Service.pas',
  ServiceHost.Host in '../src/ServiceHost.Host.pas';

type
  { --------------------------------------------------------------- services }

  { Reports a depth that wanders. Knows nothing about who reads it. }
  TPollerService = class(TBaseService)
  strict private
    FDepth: Integer;
    FRising: Boolean;
  protected
    procedure Tick(const AContext: IServiceContext); override;
  public
    constructor Create;
  end;

  { Subscribes to the poller's topic and speaks up when the depth crosses a
    line. It has no field, no constructor argument, and no compile-time
    knowledge of TPollerService — only of the string 'depth'. }
  TWatchdogService = class(TBaseService)
  strict private
    FAlerting: Boolean;
    FThreshold: Integer;
  protected
    procedure Starting(const AContext: IServiceContext); override;
    procedure Tick(const AContext: IServiceContext); override;
  public
    constructor Create(AThreshold: Integer);
    procedure OnDepth(const AEvent: TServiceEvent);
  end;

  { A heartbeat with no listeners, to show that publishing into the void costs
    the publisher nothing and is not an error. }
  TTickerService = class(TBaseService)
  strict private
    FBeats: Integer;
  protected
    procedure Tick(const AContext: IServiceContext); override;
  public
    constructor Create;
  end;

  { --------------------------------------------------------------- observer }

  { Not a service: a plain object that subscribes. Anything can subscribe. }
  TArchivist = class
  strict private
    FLock: TCriticalSection;
    FNames: TArray<string>;
    FCounts: TArray<Integer>;
    FAfterStop: Integer;
    FWatching: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const AEvent: TServiceEvent);
    procedure WatchForLateArrivalsFrom(const ASource: string);
    function LateArrivals: Integer;
    procedure Report;
  end;

var
  GStarted: TDateTime;

function Stamp: string;
begin
  Result := Format('%7.3fs', [(Now - GStarted) * 24 * 60 * 60]);
end;

procedure Say(const AWho, AWhat: string);
begin
  WriteLn(Format('%s  %-10s %s', [Stamp, AWho, AWhat]));
end;

{ ------------------------------------------------------------------ poller }

constructor TPollerService.Create;
begin
  inherited Create('poller', 120, 'reports a queue depth');
  FDepth := 4;
  FRising := True;
end;

procedure TPollerService.Tick(const AContext: IServiceContext);
begin
  if FRising then
    Inc(FDepth, 3)
  else
    Dec(FDepth, 2);
  if FDepth >= 18 then
    FRising := False
  else if FDepth <= 2 then
    FRising := True;

  { The datum is the number. A subscriber reads it without parsing anything. }
  AContext.Info('depth', 'queue depth sampled', FDepth);
end;

{ ---------------------------------------------------------------- watchdog }

constructor TWatchdogService.Create(AThreshold: Integer);
begin
  inherited Create('watchdog', 250, 'alerts on depth');
  FThreshold := AThreshold;
end;

procedure TWatchdogService.Starting(const AContext: IServiceContext);
begin
  AContext.Info('ready', Format('watching for depth above %d', [FThreshold]));
end;

procedure TWatchdogService.OnDepth(const AEvent: TServiceEvent);
begin
  { Runs on the dispatcher, not on the poller's thread and not on this
    service's own thread. The poller is not waiting for this to return. }
  if (AEvent.Datum > FThreshold) and not FAlerting then
  begin
    FAlerting := True;
    Say('watchdog', Format('depth %d is above %d', [AEvent.Datum, FThreshold]));
  end
  else if (AEvent.Datum <= FThreshold) and FAlerting then
  begin
    FAlerting := False;
    Say('watchdog', Format('depth %d is back under %d',
      [AEvent.Datum, FThreshold]));
  end;
end;

procedure TWatchdogService.Tick(const AContext: IServiceContext);
begin
  { Nothing to do on its own schedule; it lives on what it hears. A service is
    allowed to be almost entirely reactive. }
end;

{ ------------------------------------------------------------------ ticker }

constructor TTickerService.Create;
begin
  inherited Create('ticker', 400, 'heartbeat');
end;

procedure TTickerService.Tick(const AContext: IServiceContext);
begin
  Inc(FBeats);
  { Nobody subscribes to 'beat'. This costs the ticker a queue push and no
    delivery, which is the point: publishing is not coupled to listening. }
  AContext.Info('beat', 'still here', FBeats);
end;

{ --------------------------------------------------------------- archivist }

constructor TArchivist.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TArchivist.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TArchivist.Handle(const AEvent: TServiceEvent);
var
  I: Integer;
  Found: Boolean;
begin
  FLock.Enter;
  try
    if (FWatching <> '') and SameText(AEvent.Source, FWatching) then
      Inc(FAfterStop);

    Found := False;
    for I := 0 to High(FNames) do
      if SameText(FNames[I], AEvent.Source) then
      begin
        Inc(FCounts[I]);
        Found := True;
        Break;
      end;
    if not Found then
    begin
      SetLength(FNames, Length(FNames) + 1);
      SetLength(FCounts, Length(FCounts) + 1);
      FNames[High(FNames)] := AEvent.Source;
      FCounts[High(FCounts)] := 1;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TArchivist.WatchForLateArrivalsFrom(const ASource: string);
begin
  FLock.Enter;
  try
    FWatching := ASource;
    FAfterStop := 0;
  finally
    FLock.Leave;
  end;
end;

function TArchivist.LateArrivals: Integer;
begin
  FLock.Enter;
  try
    Result := FAfterStop;
  finally
    FLock.Leave;
  end;
end;

procedure TArchivist.Report;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FNames) do
      if FCounts[I] = 1 then
        WriteLn(Format('    %-10s 1 event', [FNames[I]]))
      else
        WriteLn(Format('    %-10s %d events', [FNames[I], FCounts[I]]));
  finally
    FLock.Leave;
  end;
end;

{ -------------------------------------------------------------------- main }

{ True when every service started and nothing of the stopped poller was heard
  from afterwards. }
function RunNewsroom: Boolean;
var
  Host: TServiceHost;
  Watchdog: TWatchdogService;
  Archivist: TArchivist;
  Late: Integer;
begin
  Result := False;
  GStarted := Now;
  Host := TServiceHost.Create;
  Archivist := TArchivist.Create;
  try
    Watchdog := TWatchdogService.Create(12);

    Host.Register(TPollerService.Create);
    Host.Register(Watchdog);
    Host.Register(TTickerService.Create);

    { The watchdog hears the poller. Neither one was told about the other; the
      wiring is here, at the top, where someone reading main can see it. }
    Host.Bus.Subscribe(Watchdog.OnDepth, saBackground, 'poller', 'depth');

    { The archivist hears everyone. An empty filter means no filter. }
    Host.Bus.Subscribe(Archivist.Handle, saBackground);

    WriteLn('three services on three threads, no references between them');
    WriteLn;
    Host.StartAll;
    if not Host.WaitRunning(['poller', 'watchdog', 'ticker'], 2000) then
    begin
      WriteLn('services did not start');
      Exit;
    end;
    Say('host', 'all running');

    TThread.Sleep(1600);

    { Stop the poller while it certainly still has events in flight, then ask
      whether any of them arrived afterwards. Cancel, join, discard — after
      Stop returns, "stopped" means nothing of it is left anywhere. }
    WriteLn;
    Say('host', 'stopping the poller mid-flight');
    if not Host.Stop('poller') then
      Say('host', 'the poller did not stop in time');
    { Count from the moment Stop returns: an event delivered while the stop
      was still in progress is on time, not late. }
    Archivist.WatchForLateArrivalsFrom('poller');

    TThread.Sleep(400);
    Late := Archivist.LateArrivals;
    Say('host', Format('events from the poller after Stop returned: %d', [Late]));

    TThread.Sleep(600);
    WriteLn;
    Say('host', 'stopping everything');
    Host.StopAll;

    WriteLn;
    WriteLn('  what the archivist saw:');
    Archivist.Report;
    WriteLn;
    WriteLn(Format('  published %d, delivered %d, dropped %d',
      [Host.Bus.Published_, Host.Bus.Delivered, Host.Bus.Dropped]));

    if Late <> 0 then
    begin
      WriteLn;
      WriteLn('  a stopped service was still being heard from — that is a bug');
    end;
    Result := Late = 0;
  finally
    Host.Free;
    Archivist.Free;
  end;
end;

var
  Passed: Boolean;

begin
  try
    Passed := RunNewsroom;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Passed := False;
    end;
  end;

  WriteLn;
  if Passed then
    WriteLn('Newsroom: OK')
  else
  begin
    WriteLn('Newsroom: FAILED');
    ExitCode := 1;
  end;

  { Only under the Delphi debugger (F9), so the console window stays open long
    enough to read. A plain run, a script or CI never waits here. }
  {$IFNDEF FPC}
  if DebugHook <> 0 then
  begin
    Write('Press Enter to exit...');
    ReadLn;
  end;
  {$ENDIF}
end.
