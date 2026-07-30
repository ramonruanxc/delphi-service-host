{
  ServiceHost — assertion runner with a watchdog.

  Same runner as the sibling repos. The watchdog matters here for the same
  reason it mattered there: every failure mode in a service host is a thread
  that stopped making progress, and a suite that hangs names nobody.
}
unit ServiceHost.Testing;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs{$ENDIF};

type
  TTestRunner = class
  strict private
    FPassed: Integer;
    FFailed: Integer;
    FSuiteName: string;
    FHeaderWritten: Boolean;
    FLock: TCriticalSection;
    FCurrentTest: string;
    FCurrentStart: UInt64;
    FWatchdog: TThread;
    FWatchdogLimit: Cardinal;
    procedure EnsureHeader;
    procedure Pass(const ATestName: string);
    procedure Fail(const ATestName, AExpected, AActual: string);
  private
    function CurrentTestSnapshot(out AElapsedMs: Cardinal): string;
    function WatchdogLimitMs: Cardinal;
  public
    constructor Create;
    destructor Destroy; override;
    procedure StartWatchdog(ALimitSeconds: Cardinal);
    procedure Suite(const AName: string);
    procedure Begins(const ATestName: string);
    procedure IsTrue(const ATestName: string; ACondition: Boolean);
    procedure IsFalse(const ATestName: string; ACondition: Boolean);
    procedure AreEqual(const ATestName: string; AExpected, AActual: Integer); overload;
    procedure AreEqual(const ATestName, AExpected, AActual: string); overload;
    function Finish: Integer;
    property Passed: Integer read FPassed;
    property Failed: Integer read FFailed;
  end;

implementation

uses
  ConcurrentPool.Types;

type
  TWatchdogThread = class(TThread)
  strict private
    FRunner: TTestRunner;
  protected
    procedure Execute; override;
  public
    constructor Create(ARunner: TTestRunner);
  end;

constructor TWatchdogThread.Create(ARunner: TTestRunner);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRunner := ARunner;
end;

procedure TWatchdogThread.Execute;
var
  Name: string;
  Gone, Limit: Cardinal;
begin
  Limit := FRunner.WatchdogLimitMs;
  while not Terminated do
  begin
    Name := FRunner.CurrentTestSnapshot(Gone);
    if (Name <> '') and (Gone > Limit) then
    begin
      WriteLn;
      WriteLn(Format('WATCHDOG: test "%s" exceeded %d s and is presumed ' +
        'deadlocked.', [Name, Limit div 1000]));
      WriteLn('No wait in this suite is unbounded, so an overrun is a hang.');
      Flush(Output);
      Halt(2);
    end;
    Sleep(100);
  end;
end;

constructor TTestRunner.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHeaderWritten := True;
end;

destructor TTestRunner.Destroy;
begin
  if FWatchdog <> nil then
  begin
    FWatchdog.Terminate;
    FWatchdog.WaitFor;
    FWatchdog.Free;
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TTestRunner.StartWatchdog(ALimitSeconds: Cardinal);
begin
  FWatchdogLimit := ALimitSeconds * 1000;
  FWatchdog := TWatchdogThread.Create(Self);
  FWatchdog.Start;
end;

function TTestRunner.WatchdogLimitMs: Cardinal;
begin
  Result := FWatchdogLimit;
end;

function TTestRunner.CurrentTestSnapshot(out AElapsedMs: Cardinal): string;
begin
  FLock.Enter;
  try
    Result := FCurrentTest;
    if Result = '' then
      AElapsedMs := 0
    else
      AElapsedMs := Elapsed(FCurrentStart);
  finally
    FLock.Leave;
  end;
end;

procedure TTestRunner.Begins(const ATestName: string);
begin
  FLock.Enter;
  try
    FCurrentTest := ATestName;
    FCurrentStart := Ticks;
  finally
    FLock.Leave;
  end;
end;

procedure TTestRunner.Suite(const AName: string);
begin
  FSuiteName := AName;
  FHeaderWritten := False;
end;

procedure TTestRunner.EnsureHeader;
begin
  if FHeaderWritten then
    Exit;
  WriteLn;
  WriteLn(FSuiteName);
  FHeaderWritten := True;
end;

procedure TTestRunner.Pass(const ATestName: string);
begin
  EnsureHeader;
  Inc(FPassed);
  WriteLn('  ok      ', ATestName);
  Flush(Output);
  { Re-armed rather than cleared, so a hang BETWEEN assertions is still
    reported and localised. }
  Begins('(after) ' + ATestName);
end;

procedure TTestRunner.Fail(const ATestName, AExpected, AActual: string);
begin
  EnsureHeader;
  Inc(FFailed);
  WriteLn('  FAILED  ', ATestName);
  WriteLn('            expected: ', AExpected);
  WriteLn('            actual:   ', AActual);
  Flush(Output);
  Begins('(after) ' + ATestName);
end;

procedure TTestRunner.IsTrue(const ATestName: string; ACondition: Boolean);
begin
  if ACondition then Pass(ATestName) else Fail(ATestName, 'True', 'False');
end;

procedure TTestRunner.IsFalse(const ATestName: string; ACondition: Boolean);
begin
  if not ACondition then Pass(ATestName) else Fail(ATestName, 'False', 'True');
end;

procedure TTestRunner.AreEqual(const ATestName: string; AExpected, AActual: Integer);
begin
  if AExpected = AActual then Pass(ATestName)
  else Fail(ATestName, IntToStr(AExpected), IntToStr(AActual));
end;

procedure TTestRunner.AreEqual(const ATestName, AExpected, AActual: string);
begin
  if AExpected = AActual then Pass(ATestName)
  else Fail(ATestName, '"' + AExpected + '"', '"' + AActual + '"');
end;

function TTestRunner.Finish: Integer;
begin
  Begins('');
  WriteLn;
  WriteLn('----------------------------------------');
  WriteLn(Format('%d passed, %d failed, %d total',
    [FPassed, FFailed, FPassed + FFailed]));
  if FFailed = 0 then Result := 0 else Result := 1;
end;

end.
