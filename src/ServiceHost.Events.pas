{
  ServiceHost — the event vocabulary.

  Long-lived services each run in their own thread, so the only way they can
  talk is by publishing events that someone else subscribes to. This unit
  defines what an event IS; ServiceHost.Bus defines how it travels.

  The one decision that shapes everything here is PAYLOAD OWNERSHIP.

  The design this was extracted from carried the payload as a raw
  `Data: Pointer` plus a length, and handed that same pointer to every
  subscriber. With one subscriber the ownership is merely unstated; with N it is
  undefined — if any one of them frees it the others read freed memory, and if
  none of them does it leaks. There is no rule the publisher can follow that is
  correct for both cases.

  A reference-counted interface answers the question by construction: the
  publisher creates it and lets go, the bus holds it while delivery is pending,
  every subscriber holds it while handling, and whoever releases last frees it.
  Nobody has to know who that is.
}
unit ServiceHost.Events;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF};

type
  { Severity, matching the shape the original used. Kept small on purpose: a
    level is for filtering, not for carrying meaning — that is what the topic
    and the payload are for. }
  TEventLevel = (elDebug, elInfo, elSuccess, elWarning, elError);

  { Where a subscriber's handler must run.

    saBackground runs on the bus's dispatch thread. saMainThread queues the
    event until the application calls DeliverPending from its main thread —
    typically Application.OnIdle in a VCL app, or the main loop of a console
    one.

    Delivery is NOT done with TThread.Queue. That would work in a VCL
    application and quietly do nothing in a console one, where the RTL only
    drains the queue if something calls CheckSynchronize — and it would make the
    tests non-deterministic, which for a library whose subject is threading is
    the wrong trade. An explicit pump costs the application one line and makes
    "the handler ran on the main thread" a testable fact. }
  TThreadAffinity = (saBackground, saMainThread);

  { Anything a service wants to send along with an event.

    Implementations are ordinary classes descending from TInterfacedObject, so
    a service can define its own — an entity list, a position, a parsed frame —
    without this unit knowing about it. Describe exists so a log line or a test
    failure can say something useful about a payload it does not understand. }
  IEventPayload = interface
    ['{5A0F3C71-9D42-4E8B-B6A3-1C7E20D4F853}']
    function Describe: string;
  end;

  { One published event.

    A record rather than a class: it is copied into the queue and into each
    subscriber's delivery, and a record with a managed interface field does that
    correctly and without an allocation per hop. }
  TServiceEvent = record
    { Which service published it. Subscriptions filter on this. }
    Source: string;
    { A short, stable name for what happened — 'position', 'entities-updated'.
      Subscribers filter on this and dedup keys are built from it. }
    Topic: string;
    Level: TEventLevel;
    { A human-readable line, for logs. Never parsed: the original encoded
      structure into this string with a delimiter and split it on the way out,
      which turns a typo into a runtime failure. Structure belongs in Payload. }
    Message: string;
    { The small, cheap datum most events actually need — a count, a status, an
      id — so that the common case costs no allocation at all. }
    Datum: Integer;
    { Optional. nil is normal and means "the message and the datum are the
      whole story". }
    Payload: IEventPayload;

    class function Create(const ASource, ATopic: string; ALevel: TEventLevel;
      const AMessage: string; ADatum: Integer;
      APayload: IEventPayload): TServiceEvent; static;
  end;

  { What a subscriber is handed. A method pointer, not an anonymous method:
    Free Pascal 3.2 has no `reference to procedure` at all. }
  TEventHandler = procedure(const AEvent: TServiceEvent) of object;

function LevelName(ALevel: TEventLevel): string;

{ ------------------------------------------------------------- payloads }

type
  { A couple of ready-made payloads, so the common cases do not each need a
    class. Anything richer is the caller's to define. }
  TStringPayload = class(TInterfacedObject, IEventPayload)
  strict private
    FValue: string;
  public
    constructor Create(const AValue: string);
    function Describe: string;
    function Value: string;
  end;

  TIntegerArrayPayload = class(TInterfacedObject, IEventPayload)
  strict private
    FValues: TArray<Integer>;
  public
    constructor Create(const AValues: TArray<Integer>);
    function Describe: string;
    function Values: TArray<Integer>;
    function Count: Integer;
  end;

implementation

class function TServiceEvent.Create(const ASource, ATopic: string;
  ALevel: TEventLevel; const AMessage: string; ADatum: Integer;
  APayload: IEventPayload): TServiceEvent;
begin
  Result.Source := ASource;
  Result.Topic := ATopic;
  Result.Level := ALevel;
  Result.Message := AMessage;
  Result.Datum := ADatum;
  Result.Payload := APayload;
end;

function LevelName(ALevel: TEventLevel): string;
begin
  case ALevel of
    elDebug:   Result := 'DEBUG';
    elInfo:    Result := 'INFO';
    elSuccess: Result := 'OK';
    elWarning: Result := 'WARN';
    elError:   Result := 'ERROR';
  else
    Result := '?';
  end;
end;

{ TStringPayload }

constructor TStringPayload.Create(const AValue: string);
begin
  inherited Create;
  FValue := AValue;
end;

function TStringPayload.Describe: string;
begin
  Result := 'string(' + IntToStr(Length(FValue)) + ' chars)';
end;

function TStringPayload.Value: string;
begin
  Result := FValue;
end;

{ TIntegerArrayPayload }

constructor TIntegerArrayPayload.Create(const AValues: TArray<Integer>);
var
  I: Integer;
begin
  inherited Create;
  { Copied on the way in. The publisher's array is its own business, and a
    payload that aliased it would reintroduce exactly the shared-mutable-state
    problem the interface exists to remove. }
  SetLength(FValues, Length(AValues));
  for I := 0 to High(AValues) do
    FValues[I] := AValues[I];
end;

function TIntegerArrayPayload.Describe: string;
begin
  Result := 'integers(' + IntToStr(Length(FValues)) + ')';
end;

function TIntegerArrayPayload.Values: TArray<Integer>;
begin
  Result := FValues;
end;

function TIntegerArrayPayload.Count: Integer;
begin
  Result := Length(FValues);
end;

end.
