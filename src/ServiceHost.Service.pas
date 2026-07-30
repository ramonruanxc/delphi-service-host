{
  ServiceHost — what a service is.

  A service is a named thing that wakes on an interval, does a unit of work, and
  publishes what it found. It runs in its own thread and never calls another
  service directly; the bus is the only channel between them.

  Two things here are corrections rather than copies of the design this was
  extracted from.

  THE LOOP WAITS, IT DOES NOT SPIN. The original ran

      while not Terminated do
      begin
        if enough time has passed then DoWork;
        Sleep(1);
      end;

  which wakes a thousand times a second per service to decide, almost always,
  to do nothing. With nineteen services that is nineteen thousand pointless
  wake-ups a second. Here the loop waits on the cancellation token with the
  remaining interval as its timeout, so a service costs nothing between ticks
  and still stops instantly when asked.

  TIME IS MONOTONIC. The original compared Now against the previous pass with
  MilliSecondsBetween. A wall clock moves — NTP corrections, daylight saving —
  and when it moves backwards a service stalls for the offset, while forwards it
  fires a burst. Ticks is monotonic and was measured as such on every target.
}
unit ServiceHost.Service;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  ConcurrentPool.Types,
  ServiceHost.Events,
  ServiceHost.Bus;

type
  TServiceState = (svStopped, svStarting, svRunning, svStopping, svFaulted);

  { Forward: IService's methods take a context, and the context is declared
    after it because that reads in the order a user meets them. }
  IServiceContext = interface;

  IService = interface
    ['{9C41E7A2-6B3D-4F58-8E10-D25A7C6B94F1}']
    function Name: string;
    function Description: string;
    { Milliseconds between ticks. Zero means "as fast as the host will run it",
      which is almost never what you want. }
    function Interval: Integer;

    { Called once on the service's own thread before the first tick, and once
      after the last. Anything a tick needs that is expensive to build belongs
      here. Both run on the service thread, so neither needs a lock against the
      ticks. }
    procedure Starting(const AContext: IServiceContext);
    procedure Stopped;

    { One unit of work. Returns quickly, checks the token if it does anything
      long, and publishes what it learned. }
    procedure Tick(const AContext: IServiceContext);
  end;

  { What the host hands a service: its identity, its way of publishing, and its
    cancellation token. A service gets no reference to the host and no reference
    to other services — the bus is the only channel. }
  IServiceContext = interface
    ['{3F8B0D64-1A97-4C25-9B7E-58E4A1D302C6}']
    function ServiceName: string;
    function Token: ICancellationToken;

    procedure Publish(const ATopic: string; ALevel: TEventLevel;
      const AMessage: string; ADatum: Integer = 0;
      APayload: IEventPayload = nil); overload;
    procedure Info(const ATopic, AMessage: string; ADatum: Integer = 0);
    procedure Warn(const ATopic, AMessage: string; ADatum: Integer = 0);
    procedure Fail(const ATopic, AMessage: string; ADatum: Integer = 0);
    procedure Emit(const ATopic: string; APayload: IEventPayload;
      ADatum: Integer = 0);
  end;

  { A convenience base. Descend from it and override Tick; the rest has
    reasonable defaults. Implementing IService directly is equally fine — the
    host only ever sees the interface. }
  TBaseService = class(TInterfacedObject, IService)
  strict private
    FName: string;
    FDescription: string;
    FInterval: Integer;
  public
    constructor Create(const AName: string; AIntervalMs: Integer;
      const ADescription: string = '');
    function Name: string;
    function Description: string;
    function Interval: Integer;
    procedure Starting(const AContext: IServiceContext); virtual;
    procedure Stopped; virtual;
    procedure Tick(const AContext: IServiceContext); virtual; abstract;
  end;

{ Builds a context. Used by the host; exposed so a service can be exercised in a
  test without standing up a whole host. }
function MakeContext(const AServiceName: string; ABus: TEventBus;
  const AToken: ICancellationToken): IServiceContext;

implementation

type
  TServiceContext = class(TInterfacedObject, IServiceContext)
  strict private
    FName: string;
    FBus: TEventBus;
    FToken: ICancellationToken;
  public
    constructor Create(const AName: string; ABus: TEventBus;
      const AToken: ICancellationToken);
    function ServiceName: string;
    function Token: ICancellationToken;
    procedure Publish(const ATopic: string; ALevel: TEventLevel;
      const AMessage: string; ADatum: Integer; APayload: IEventPayload);
    procedure Info(const ATopic, AMessage: string; ADatum: Integer);
    procedure Warn(const ATopic, AMessage: string; ADatum: Integer);
    procedure Fail(const ATopic, AMessage: string; ADatum: Integer);
    procedure Emit(const ATopic: string; APayload: IEventPayload;
      ADatum: Integer);
  end;

constructor TServiceContext.Create(const AName: string; ABus: TEventBus;
  const AToken: ICancellationToken);
begin
  inherited Create;
  FName := AName;
  FBus := ABus;
  FToken := AToken;
end;

function TServiceContext.ServiceName: string;
begin
  Result := FName;
end;

function TServiceContext.Token: ICancellationToken;
begin
  Result := FToken;
end;

procedure TServiceContext.Publish(const ATopic: string; ALevel: TEventLevel;
  const AMessage: string; ADatum: Integer; APayload: IEventPayload);
begin
  { The source is stamped by the context, not passed by the caller: a service
    cannot publish under another service's name, so a subscriber filtering on a
    source is filtering on something the publisher could not forge. }
  FBus.Publish(FName, ATopic, ALevel, AMessage, ADatum, APayload);
end;

procedure TServiceContext.Info(const ATopic, AMessage: string; ADatum: Integer);
begin
  Publish(ATopic, elInfo, AMessage, ADatum, nil);
end;

procedure TServiceContext.Warn(const ATopic, AMessage: string; ADatum: Integer);
begin
  Publish(ATopic, elWarning, AMessage, ADatum, nil);
end;

procedure TServiceContext.Fail(const ATopic, AMessage: string; ADatum: Integer);
begin
  Publish(ATopic, elError, AMessage, ADatum, nil);
end;

procedure TServiceContext.Emit(const ATopic: string; APayload: IEventPayload;
  ADatum: Integer);
begin
  Publish(ATopic, elSuccess, '', ADatum, APayload);
end;

function MakeContext(const AServiceName: string; ABus: TEventBus;
  const AToken: ICancellationToken): IServiceContext;
begin
  Result := TServiceContext.Create(AServiceName, ABus, AToken);
end;

{ TBaseService }

constructor TBaseService.Create(const AName: string; AIntervalMs: Integer;
  const ADescription: string);
begin
  inherited Create;
  if Trim(AName) = '' then
    raise EPoolArgument.Create('A service needs a name.');
  if AIntervalMs < 0 then
    raise EPoolArgument.CreateFmt(
      'Interval cannot be negative, got %d.', [AIntervalMs]);
  FName := AName;
  FInterval := AIntervalMs;
  FDescription := ADescription;
end;

function TBaseService.Name: string;
begin
  Result := FName;
end;

function TBaseService.Description: string;
begin
  Result := FDescription;
end;

function TBaseService.Interval: Integer;
begin
  Result := FInterval;
end;

procedure TBaseService.Starting(const AContext: IServiceContext);
begin
  { Nothing by default. }
end;

procedure TBaseService.Stopped;
begin
  { Nothing by default. }
end;

end.
