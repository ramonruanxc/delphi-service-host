{
  ServiceHost test runner.

    Free Pascal   fpc -Mdelphi -Sa -Fusrc -Futests \
                    -Fulib/concurrent-pool \
                    -FUbuild/normal -obuild/Tests tests/Tests.dpr
    Delphi        open in the IDE and build; the uses clause carries every path

  Exits non-zero if any assertion fails, and Halt(2) from the watchdog if a test
  overruns — which in a service host means a thread stopped making progress.
}
program Tests;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IF DEFINED(FPC) AND DEFINED(UNIX)}
  cthreads,
  {$IFEND}
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  { The dependency, vendored at an exact commit (lib/concurrent-pool/
    PROVENANCE.md) so it is part of this repository's history rather than
    "whatever main happened to be". }
  ConcurrentPool.Types in '../lib/concurrent-pool/ConcurrentPool.Types.pas',
  ConcurrentPool.Atomic in '../lib/concurrent-pool/ConcurrentPool.Atomic.pas',
  ConcurrentPool.Queue in '../lib/concurrent-pool/ConcurrentPool.Queue.pas',
  ConcurrentPool.Worker in '../lib/concurrent-pool/ConcurrentPool.Worker.pas',
  ServiceHost.Events in '../src/ServiceHost.Events.pas',
  ServiceHost.Bus in '../src/ServiceHost.Bus.pas',
  ServiceHost.Service in '../src/ServiceHost.Service.pas',
  ServiceHost.Host in '../src/ServiceHost.Host.pas',
  ServiceHost.Testing in 'ServiceHost.Testing.pas',
  ServiceHost.Tests in 'ServiceHost.Tests.pas';

{ Accepts one dash, two, or a slash. FindCmdLineSwitch takes PREFIX CHARACTERS,
  so with ['-'] it reads '--flag' as the switch '-flag' and quietly fails to
  match — which is how a flag came to be ignored in a sibling repo's CI. }
function HasFlag(const AName: string): Boolean;
var
  I: Integer;
  P: string;
begin
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if SameText(P, '--' + AName) or SameText(P, '-' + AName) or
       SameText(P, '/' + AName) then
      Exit(True);
  end;
  Result := False;
end;

function GetWatchdogArg: string;
var
  I, Eq: Integer;
  P: string;
begin
  Result := '';
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    Eq := Pos('=', P);
    if Eq = 0 then
      Continue;
    if SameText(Copy(P, 1, Eq - 1), '--watchdog') or
       SameText(Copy(P, 1, Eq - 1), '-watchdog') then
      Exit(Copy(P, Eq + 1, MaxInt));
  end;
end;

var
  Runner: TTestRunner;
  WatchdogSeconds: Integer;
  Arg: string;
begin
  WriteLn('ServiceHost test suite');
  {$IFDEF FPC}
  WriteLn('compiler : Free Pascal');
  {$ELSE}
  WriteLn('compiler : Delphi');
  {$ENDIF}
  {$IFOPT C+}
  WriteLn('asserts  : on');
  {$ELSE}
  WriteLn('asserts  : OFF — build with -Sa');
  {$ENDIF}

  WatchdogSeconds := 60;
  Arg := GetWatchdogArg;
  if Arg <> '' then
    WatchdogSeconds := StrToIntDef(Arg, 60);
  WriteLn('watchdog : ', WatchdogSeconds, ' s per test');
  if HasFlag('quiet') then
    WriteLn('quiet    : on');

  Runner := TTestRunner.Create;
  try
    Runner.StartWatchdog(WatchdogSeconds);
    RunTests(Runner);
    ExitCode := Runner.Finish;
  finally
    Runner.Free;
  end;
end.
