{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

program abdeckercli;

{ abdecker - command line tool: parse the arguments, run the command.
  The commands live in commands, console and file helpers in cliutils.
  Program and file name must differ from the unit name "abdecker" (under
  FPC both would yield abdecker.o); the build scripts name the result
  abdecker(.exe). }

{$IFDEF MSWINDOWS}
  {$APPTYPE CONSOLE}
{$ENDIF}
{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
{$IFDEF FPC}
  {$IFDEF UNIX} cthreads, {$ENDIF}  // first: serve uses threads
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  abdecker in '..\source\abdecker.pas',
  cliutils in 'cliutils.pas',
  clihelp in 'clihelp.pas',
  commands in 'commands.pas',
{$IFDEF FPC}
  sock_fpc in 'sock_fpc.pas',
{$ELSE}
  sock_delphi in 'sock_delphi.pas',
{$ENDIF}
  http in 'http.pas',
  serve in 'serve.pas';

function ParseArgs(out o: TCliOptions): Boolean;
var
  i: Integer;
  a: string;

  { value of a numeric option: 1..Max }
  function Number(out n: Integer; Max: Integer): Boolean;
  begin
    result := false;
    Inc(i);
    if i > ParamCount then begin
      Writeln(ErrOutput, 'Error: number missing after ', a);
      exit;
    end;
    if not TryStrToInt(ParamStr(i), n) or (n < 1) or (n > Max) then begin
      Writeln(ErrOutput, 'Error: ', a, ' needs a number from 1 to ', Max);
      exit;
    end;
    result := true;
  end;

begin
  result := false;
  o := Default(TCliOptions);
  o.FailOn := abError;
  o.Command := LowerCase(ParamStr(1));
  i := 2;
  while i <= ParamCount do begin
    a := ParamStr(i);
    if (a = '-o') or (a = '--output') then begin
      Inc(i);
      if i > ParamCount then begin
        Writeln(ErrOutput, 'Error: file name missing after ', a);
        exit;
      end;
      o.Output := ParamStr(i);
    end else if a = '--json' then begin
      o.Json := true;
    end else if a = '--open' then begin
      o.Open := true;
    end else if a = '--no-check' then begin
      o.NoCheck := true;
    end else if a = '--payment' then begin
      o.Payment := true;
    end else if a = '--fail-on' then begin
      Inc(i);
      if i > ParamCount then begin
        Writeln(ErrOutput, 'Error: severity missing after --fail-on (error or warning)');
        exit;
      end;
      a := LowerCase(ParamStr(i));
      if a = 'error' then begin
        o.FailOn := abError;
      end else if a = 'warning' then begin
        o.FailOn := abWarning;
      end else begin
        Writeln(ErrOutput, 'Error: --fail-on must be error or warning');
        exit;
      end;
    end else if a = '--lang' then begin
      Inc(i);
      if i > ParamCount then begin
        Writeln(ErrOutput, 'Error: language missing after --lang (de or en)');
        exit;
      end;
      o.Lang := LowerCase(ParamStr(i));
      if (o.Lang <> 'de') and (o.Lang <> 'en') then begin
        Writeln(ErrOutput, 'Error: --lang must be de or en');
        exit;
      end;
    end else if a = '--host' then begin
      Inc(i);
      if i > ParamCount then begin
        Writeln(ErrOutput, 'Error: address missing after --host');
        exit;
      end;
      o.Host := ParamStr(i);
    end else if a = '--index' then begin
      if not Number(o.Index, 9999) then exit;
    end else if a = '--port' then begin
      if not Number(o.Port, 65535) then exit;
    end else if a = '--max-size' then begin
      if not Number(o.MaxSize, 2047) then exit;
    end else if a = '--workers' then begin
      if not Number(o.Workers, 256) then exit;
    end else if a = '--queue' then begin
      if not Number(o.Queue, 10000) then exit;
    end else if a = '--timeout' then begin
      if not Number(o.Timeout, 3600) then exit;
    end else if a = '--quiet' then begin
      o.Quiet := true;
    end else if a = '--test-routes' then begin   // undocumented: routes for the server tests
      o.TestRoutes := true;
    end else if a = '--var' then begin
      Inc(i);
      if (i > ParamCount) or (Pos('=', ParamStr(i)) < 2) then begin
        Writeln(ErrOutput, 'Error: --var needs name=value');
        exit;
      end;
      SetLength(o.Vars, Length(o.Vars) + 1);
      o.Vars[High(o.Vars)] := ParamStr(i);
    end else if a = '--vars' then begin
      Inc(i);
      if i > ParamCount then begin
        Writeln(ErrOutput, 'Error: file name missing after --vars');
        exit;
      end;
      o.VarsFile := ParamStr(i);
    end else if (a = '-f') or (a = '--force') then begin
      o.Force := true;
    end else if (a = '-h') or (a = '--help') then begin
      o.Help := true;
    end else if (a = '-v') or (a = '--verbose') then begin
      o.Verbose := true;
    end else if (Length(a) > 1) and (a[1] = '-') then begin
      Writeln(ErrOutput, 'Error: unknown option ', a);
      exit;
    end else begin
      SetLength(o.Positional, Length(o.Positional) + 1);
      o.Positional[High(o.Positional)] := a;
    end;
    Inc(i);
  end;
  result := true;
end;

function Run: Integer;
var
  o: TCliOptions;
begin
  if ParamCount = 0 then begin
    PrintOverview;
    exit(2);
  end;

  if not ParseArgs(o) then exit(UsageError(o.Command));

  if (o.Command = '-h') or (o.Command = '--help') then begin
    PrintOverview;
    result := 0;
  end else if o.Command = 'help' then begin
    if Length(o.Positional) = 0 then begin
      PrintOverview;
      result := 0;
    end else if Length(o.Positional) > 1 then begin
      result := UsageError('help');
    end else if PrintCommandHelp(o.Positional[0]) then begin
      result := 0;
    end else begin
      Writeln(ErrOutput, 'Unknown command "', o.Positional[0], '". Run "abdecker help" for the list of commands.');
      result := 2;
    end;
  end else if o.Help then begin
    if PrintCommandHelp(o.Command) then begin
      result := 0;
    end else begin
      Writeln(ErrOutput, 'Unknown command "', o.Command, '". Run "abdecker help" for the list of commands.');
      result := 2;
    end;
  end else if (o.Command = 'version') or (o.Command = '--version') then begin
    Writeln('abdecker ', AbdeckerVersion, ' by ', AbdeckerAuthor);
    Writeln(AbdeckerRepo);
    Writeln(AbdeckerHome);
    result := 0;
  end else if o.Command = 'info' then begin
    result := RunInfo(o);
  end else if o.Command = 'extract' then begin
    result := RunExtract(o);
  end else if o.Command = 'check' then begin
    result := RunCheck(o);
  end else if o.Command = 'embed' then begin
    result := RunEmbed(o);
  end else if o.Command = 'strip' then begin
    result := RunStrip(o);
  end else if o.Command = 'attach' then begin
    result := RunAttach(o);
  end else if o.Command = 'attachments' then begin
    result := RunAttachments(o);
  end else if o.Command = 'html' then begin
    result := RunHtml(o);
  end else if o.Command = 'json' then begin
    result := RunJson(o);
  end else if o.Command = 'create' then begin
    result := RunCreate(o);
  end else if o.Command = 'serve' then begin
    result := RunServe(o);
  end else begin
    Writeln(ErrOutput, 'Unknown command "', o.Command, '". Run "abdecker help" for the list of commands.');
    result := 2;
  end;
end;

begin
  SetupConsole;
  try
    ExitCode := Run;
  except
    on e: Exception do begin
      Writeln(ErrOutput, 'Internal error: ', e.Message);
      ExitCode := 2;
    end;
  end;
end.
