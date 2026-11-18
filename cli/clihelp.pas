{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit clihelp;

{ abdecker - help of the command line tool: the overview ("abdecker help"),
  one page per command ("abdecker help <command>", "abdecker <command> -h")
  and the short usage line after a wrong call.

  Layout: text at most 79 columns wide, running text unindented, lists
  (options, exit codes, examples) indented by two. The texts are wrapped by
  hand, not at run time. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

{ the overview: all commands by group }
procedure PrintOverview;
{ the page of a command; false if there is no such command }
function PrintCommandHelp(const Name: string): Boolean;
{ after a wrong call: usage line and hint to standard error, result 2 (exit code) }
function UsageError(const Name: string): Integer;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  abdecker;

type
  TCmdGroup = (cgRead, cgWrite, cgOther);

  TCmdInfo = record
    Name: string;
    Group: TCmdGroup;
    Short: string;     // one line in the overview
    Synopsis: string;  // after "Usage: "
  end;

const
  GroupNames: array[TCmdGroup] of string = ('Reading', 'Writing', 'Other');

  Commands: array[0..12] of TCmdInfo = (
    (Name: 'info'; Group: cgRead; Short: 'show format, profile and key data of an invoice';
      Synopsis: 'abdecker info <input.pdf|input.xml> [--json]'),
    (Name: 'check'; Group: cgRead; Short: 'check an invoice against EN 16931 and XRechnung';
      Synopsis: 'abdecker check <input.pdf|input.xml> [options]'),
    (Name: 'html'; Group: cgRead; Short: 'render an invoice as an HTML page';
      Synopsis: 'abdecker html <input.pdf|input.xml> [-o <output.html>] [options]'),
    (Name: 'json'; Group: cgRead; Short: 'an invoice as JSON for further processing';
      Synopsis: 'abdecker json <input.pdf|input.xml> [-o <output.json>] [-f]'),
    (Name: 'attachments'; Group: cgRead; Short: 'list or save the files that come with an invoice';
      Synopsis: 'abdecker attachments <input.pdf|input.xml> [-o <folder|file>] [options]'),
    (Name: 'extract'; Group: cgRead; Short: 'extract the invoice XML from a PDF';
      Synopsis: 'abdecker extract <input.pdf> [-o <output.xml>] [-f]'),
    (Name: 'create'; Group: cgWrite; Short: 'create an invoice from the own JSON format';
      Synopsis: 'abdecker create <invoice.json> [-o <output.xml>] [options]'),
    (Name: 'embed'; Group: cgWrite; Short: 'embed an invoice XML into a PDF (ZUGFeRD, Factur-X)';
      Synopsis: 'abdecker embed <input.pdf> <invoice.xml> [-o <output.pdf>] [-f]'),
    (Name: 'attach'; Group: cgWrite; Short: 'add files to an invoice XML';
      Synopsis: 'abdecker attach <invoice.xml> <file>... [-o <output.xml>] [-f]'),
    (Name: 'strip'; Group: cgWrite; Short: 'remove the invoice XML from a PDF';
      Synopsis: 'abdecker strip <input.pdf> [-o <output.pdf>] [-f]'),
    (Name: 'serve'; Group: cgOther; Short: 'run the REST/JSON server';
      Synopsis: 'abdecker serve [options]'),
    (Name: 'help'; Group: cgOther; Short: 'show help for a command';
      Synopsis: 'abdecker help [<command>]'),
    (Name: 'version'; Group: cgOther; Short: 'show the version';
      Synopsis: 'abdecker version'));

function FindCommand(const Name: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(Commands) do begin
    if Commands[i].Name = LowerCase(Name) then exit(i);
  end;

  result := -1;
end;

procedure PrintOverview;
var
  g: TCmdGroup;
  i: Integer;
begin
  Writeln('abdecker ', AbdeckerVersion, ' - e-invoices (XRechnung, ZUGFeRD, Factur-X)');
  Writeln;
  Writeln('Usage: abdecker <command> [arguments]');

  for g := Low(TCmdGroup) to High(TCmdGroup) do begin
    Writeln;
    Writeln(GroupNames[g], ':');

    for i := 0 to High(Commands) do begin
      if Commands[i].Group = g then begin
        Writeln('  ', Format('%-14s', [Commands[i].Name]), Commands[i].Short);
      end;
    end;
  end;

  Writeln;
  Writeln('Run "abdecker help <command>" for more about a command.');
end;

{ ---- building blocks of the pages ---- }

procedure Heading(const Title: string);
begin
  Writeln;
  Writeln(Title, ':');
end;

{ one option: name column 24 wide, then the text (continuation lines indented) }
procedure Opt(const Name, Text: string);
begin
  Writeln('  ', Format('%-24s', [Name]), Text);
end;

procedure More(const Text: string);
begin
  Writeln(StringOfChar(' ', 26), Text);
end;

procedure OptOutput(const What: string);
begin
  Opt('-o, --output <file>', What + '; "-" = standard output');
end;

procedure OptForce;
begin
  Opt('-f, --force', 'overwrite an existing output file');
end;

procedure OptFailOn;
begin
  Opt('--fail-on <level>', 'error (default): exit code 1 on errors;');
  More('warning: also on warnings');
end;

{ exit codes: what 0 and 1 mean for this command; 2 is the same everywhere }
procedure ExitCodes(const Zero, One: array of string);
var
  i: Integer;
begin
  Heading('Exit codes');

  for i := 0 to High(Zero) do begin
    if i = 0 then begin
      Writeln('  0  ', Zero[i]);
    end else begin
      Writeln('     ', Zero[i]);
    end;
  end;

  for i := 0 to High(One) do begin
    if i = 0 then begin
      Writeln('  1  ', One[i]);
    end else begin
      Writeln('     ', One[i]);
    end;
  end;

  Writeln('  2  failure: file, usage, encrypted PDF, internal error');
end;

procedure StdinNote;
begin
  Writeln;
  Writeln('"-" as input reads from standard input.');
end;

{ ---- the pages ---- }

procedure HelpInfo;
begin
  Writeln('Shows the format of an e-invoice (container, syntax, profile) and its key');
  Writeln('data: number, date, type, seller, buyer, totals. For a PDF also the files');
  Writeln('embedded in it. Messages from reading (not a check) come at the end.');
  StdinNote;
  Heading('Options');
  Opt('--json', 'machine-readable output');
  ExitCodes(['e-invoice found'], ['no (readable) e-invoice']);
  Heading('Example');
  Writeln('  abdecker info invoice.pdf');
end;

procedure HelpCheck;
begin
  Writeln('Checks an e-invoice against the rules of EN 16931 and, for XRechnung, the');
  Writeln('XRechnung and Peppol rules. Rule IDs are the official ones (BR-..., BR-DE-...);');
  Writeln('"(extra check)" marks checks beyond the official rules. A plausibility check,');
  Writeln('not a replacement for the official validators.');
  Writeln;
  Writeln('With -v, the report lists every rule of the applied rule sets: passed,');
  Writeln('failed, or not applied (the invoice does not contain what the rule is about,');
  Writeln('or it cannot be decided; see the list of what was not checked).');
  StdinNote;
  Heading('Options');
  Opt('--json', 'machine-readable output');
  Opt('-v, --verbose', 'list every rule by status (--json: the field "rules")');
  OptFailOn;
  ExitCodes(['no errors (with --fail-on warning: no warnings either)'],
    ['errors found (with --fail-on warning: also warnings),', 'or no (readable) e-invoice']);
  Heading('Examples');
  Writeln('  abdecker check invoice.xml --fail-on warning');
  Writeln('  abdecker check invoice.pdf -v');
end;

procedure HelpHtml;
begin
  Writeln('Renders an e-invoice as an HTML page, readable for people, with the check');
  Writeln('results at the top. Below the totals: what is to be paid, for a credit');
  Writeln('transfer like a transfer form with a GiroCode (QR code for banking apps).');
  Writeln('Without -o, the page goes to standard output; with --open, to a temporary');
  Writeln('file.');
  StdinNote;
  Heading('Options');
  OptOutput('output file');
  OptForce;
  Opt('--open', 'open the page in the browser');
  Opt('--lang de|en', 'language of the page, default de');
  Opt('--no-check', 'leave out the check results');
  Opt('--payment', 'only what is to be paid (to print or pay)');
  ExitCodes(['page written'], ['no (readable) e-invoice']);
  Heading('Example');
  Writeln('  abdecker html invoice.pdf --open --lang en');
end;

procedure HelpJson;
begin
  Writeln('Writes an e-invoice as JSON for further processing (accounting import,');
  Writeln('scripts): a reduced, flat view with line amounts, VAT breakdown and totals.');
  Writeln('Field names as in the own format of "create" where the meaning is the same;');
  Writeln('not meant as input for "create" (see docs/invoice-json/output.md).');
  Writeln;
  Writeln('Without -o, the JSON goes to standard output. It comes on failure, too: then');
  Writeln('with the result code and the messages, the exit code tells.');
  StdinNote;
  Heading('Options');
  OptOutput('output file');
  OptForce;
  ExitCodes(['e-invoice read'], ['no (readable) e-invoice']);
  Heading('Example');
  Writeln('  abdecker json invoice.pdf -o invoice.json');
end;

procedure HelpAttachments;
begin
  Writeln('Lists the files that come with an invoice: the files embedded in a PDF and');
  Writeln('the attachments (BG-24) inside the invoice XML, numbered. With -o, saves');
  Writeln('them all into the folder. With --index <n>, only file n: into the file');
  Writeln('given by -o, otherwise to standard output (not to the console unless -o -).');
  StdinNote;
  Heading('Options');
  Opt('-o, --output <folder>', 'save the files into this folder (created if needed);');
  More('with --index: the file, "-" = standard output');
  Opt('--index <n>', 'only file n (the number from the list)');
  Opt('-f, --force', 'overwrite existing files');
  Opt('--json', 'machine-readable output (not with --index)');
  ExitCodes(['files listed or saved (also when there are none)'],
    ['not a readable PDF or invoice XML', '--index: no such file, or it has no content']);
  Heading('Examples');
  Writeln('  abdecker attachments invoice.pdf -o attachments');
  Writeln('  abdecker attachments invoice.pdf --index 2 -o timesheet.pdf');
end;

procedure HelpExtract;
begin
  Writeln('Extracts the embedded invoice XML from a ZUGFeRD or Factur-X PDF, byte for');
  Writeln('byte as it is in the PDF. Without -o, the XML goes to standard output.');
  StdinNote;
  Heading('Options');
  OptOutput('output file');
  OptForce;
  ExitCodes(['XML extracted'], ['no e-invoice in the PDF']);
  Heading('Example');
  Writeln('  abdecker extract invoice.pdf -o invoice.xml');
end;

procedure HelpCreate;
begin
  Writeln('Creates a CII invoice (XRechnung or EN 16931) from the own JSON format and');
  Writeln('checks it. abdecker fills in defaults and calculates line amounts, VAT');
  Writeln('breakdown and totals. Start from one of the templates (templates/*.json);');
  Writeln('the format is described in docs/invoice-json.');
  Writeln;
  Writeln('Errors in the JSON (unknown fields, wrong types ...) are reported with line');
  Writeln('and column, and no invoice is written. Findings of the check do not stop it:');
  Writeln('the XML is written, the exit code tells. Without -o, the XML goes to');
  Writeln('standard output. For ZUGFeRD/Factur-X, embed it into the PDF of the invoice');
  Writeln('with "abdecker embed".');
  StdinNote;
  Heading('Options');
  OptOutput('output file');
  OptForce;
  Opt('--var name=value', 'value for the placeholder {{name}}; repeatable');
  Opt('--vars <file.json>', 'placeholder values from a JSON object (strings and');
  More('numbers at the top level)');
  OptFailOn;
  Heading('Placeholders');
  Writeln('String values in the JSON may contain {{name}}. Built in, from today''s date:');
  Writeln('  {{today}}               today (YYYY-MM-DD)');
  Writeln('  {{today+N}}             today plus N days, e.g. {{today+14}}');
  Writeln('  {{prevMonthStart}}      first day of the previous month');
  Writeln('  {{prevMonthEnd}}        last day of the previous month');
  Writeln('Own values come from --var and --vars; --var takes precedence over --vars,');
  Writeln('both over the built-ins. A placeholder without a value is an error.');
  ExitCodes(['invoice created, the check found no errors'],
    ['invalid invoice data (nothing written), or the check found errors',
     '(with --fail-on warning: also warnings; the XML is written then)']);
  Heading('Examples');
  Writeln('  abdecker create templates/minimal.json -o invoice.xml');
  Writeln('  abdecker create invoice.json --vars values.json --var nr=2026-0815 -o out.xml');
end;

procedure HelpEmbed;
begin
  Writeln('Embeds an invoice XML into a PDF, which makes it a ZUGFeRD/Factur-X invoice:');
  Writeln('the XML as embedded file, plus the metadata that marks the PDF as such. The');
  Writeln('invoice must be CII; UBL is converted to CII first. A PDF that already');
  Writeln('contains an invoice is refused (remove it first with "abdecker strip").');
  Writeln;
  Writeln('Without -o, the PDF goes to standard output, but not to the console: then');
  Writeln('use -o, redirect the output, or force it with -o -.');
  Writeln;
  Writeln('"-" as input reads one of the two from standard input.');
  Heading('Options');
  OptOutput('output file');
  OptForce;
  ExitCodes(['PDF written'], ['the PDF or the invoice cannot be read, or the PDF already',
    'contains an invoice']);
  Heading('Example');
  Writeln('  abdecker embed letter.pdf invoice.xml -o invoice.pdf');
end;

procedure HelpAttach;
begin
  Writeln('Adds files to an invoice XML as attachments (BG-24), e.g. a timesheet.');
  Writeln('Allowed are PDF, PNG, JPEG, CSV, XLSX and ODS. Without -o, the XML goes to');
  Writeln('standard output.');
  Writeln;
  Writeln('"-" as invoice reads it from standard input (the files cannot).');
  Heading('Options');
  OptOutput('output file');
  OptForce;
  ExitCodes(['XML written'], ['the invoice cannot be read, or a file type is not allowed']);
  Heading('Example');
  Writeln('  abdecker attach invoice.xml timesheet.pdf -o invoice-with-timesheet.xml');
end;

procedure HelpStrip;
begin
  Writeln('Removes the embedded invoice XML from a ZUGFeRD/Factur-X PDF; what remains');
  Writeln('is the plain PDF. Without -o, the PDF goes to standard output, but not to the');
  Writeln('console: then use -o, redirect the output, or force it with -o -.');
  StdinNote;
  Heading('Options');
  OptOutput('output file');
  OptForce;
  ExitCodes(['PDF written'], ['no e-invoice in the PDF']);
  Heading('Example');
  Writeln('  abdecker strip invoice.pdf -o letter.pdf');
end;

procedure HelpServe;
begin
  Writeln('Runs the functions of abdecker as a REST/JSON server, e.g. for programs in');
  Writeln('other languages. POST the file (or the JSON for /create) as request body;');
  Writeln('/embed and /attach take multipart/form-data. The interface is described at');
  Writeln('/openapi.json, interactively at /docs. Ctrl+C stops the server.');
  Writeln;
  Writeln('  POST /info /check /html /json /attachments /extract /strip /create');
  Writeln('  POST /embed /attach');
  Writeln('  GET  /version /openapi.json /docs');
  Heading('Options');
  Opt('--host <address>', 'address to listen on, default 127.0.0.1');
  Opt('--port <n>', 'port, default 8080');
  Opt('--max-size <MB>', 'largest request, default 50');
  Opt('--workers <n>', 'parallel requests, default: number of CPU cores');
  Opt('--queue <n>', 'waiting requests, default 4 x workers');
  Opt('--timeout <s>', 'deadline per request from accept, default 30');
  Opt('--quiet', 'no line per request on standard output');
  Heading('Exit codes');
  Writeln('  2  the server cannot start (e.g. the port is in use), or usage error');
  Heading('Examples');
  Writeln('  abdecker serve --port 8080');
  Writeln('  curl --data-binary @invoice.pdf http://127.0.0.1:8080/check');
end;

procedure HelpHelp;
begin
  Writeln('Without a command: the list of all commands. With a command: its options,');
  Writeln('exit codes and examples. "abdecker <command> -h" shows the same.');
end;

procedure HelpVersion;
begin
  Writeln('Shows the version, the author and the links to the project.');
end;

function PrintCommandHelp(const Name: string): Boolean;
var
  i: Integer;
  n: string;
begin
  i := FindCommand(Name);
  result := i >= 0;
  if not result then exit;
  n := Commands[i].Name;
  Writeln('Usage: ', Commands[i].Synopsis);
  Writeln;

  if n = 'info' then begin
    HelpInfo;
  end else if n = 'check' then begin
    HelpCheck;
  end else if n = 'html' then begin
    HelpHtml;
  end else if n = 'json' then begin
    HelpJson;
  end else if n = 'attachments' then begin
    HelpAttachments;
  end else if n = 'extract' then begin
    HelpExtract;
  end else if n = 'create' then begin
    HelpCreate;
  end else if n = 'embed' then begin
    HelpEmbed;
  end else if n = 'attach' then begin
    HelpAttach;
  end else if n = 'strip' then begin
    HelpStrip;
  end else if n = 'serve' then begin
    HelpServe;
  end else if n = 'help' then begin
    HelpHelp;
  end else begin
    HelpVersion;
  end;
end;

function UsageError(const Name: string): Integer;
var
  i: Integer;
begin
  i := FindCommand(Name);

  if i >= 0 then begin
    Writeln(ErrOutput, 'Usage: ', Commands[i].Synopsis);
    Writeln(ErrOutput, 'Run "abdecker help ', Commands[i].Name, '" for details.');
  end else begin
    Writeln(ErrOutput, 'Run "abdecker help" for the list of commands.');
  end;

  result := 2;
end;

end.
