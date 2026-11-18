{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit commands;

{ abdecker - the commands of the command line tool: read the input, call
  TAbdecker, write the result (text, JSON from the lib, files), map the result
  to the exit code. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  abdecker;

type
  { Parsed command line }
  TCliOptions = record
    Command: string;
    Positional: array of string;
    Output: string;      // -o, '' = default of the command
    Json, Force, Open, NoCheck: Boolean;
    Payment: Boolean;    // html --payment: only what is to be paid
    Lang: string;        // html: 'de' or 'en', '' = de
    Index: Integer;      // attachments --index: number in the list (from 1), 0 = all
    FailOn: TAbSeverity; // check, create: lowest severity that fails (abError or abWarning)
    // create
    Vars: array of string;  // --var name=value (in the order given)
    VarsFile: string;       // --vars <file.json>
    // serve
    Host: string;
    Port, MaxSize, Workers, Queue, Timeout: Integer;  // MaxSize in MB, Timeout in s; 0 = default
    Quiet, TestRoutes: Boolean;
    Help: Boolean;          // -h, --help: the help page of the command
    Verbose: Boolean;       // check -v: the status of every rule
  end;

function RunInfo(const o: TCliOptions): Integer;
function RunExtract(const o: TCliOptions): Integer;
function RunCheck(const o: TCliOptions): Integer;
function RunEmbed(const o: TCliOptions): Integer;
function RunStrip(const o: TCliOptions): Integer;
function RunAttach(const o: TCliOptions): Integer;
function RunAttachments(const o: TCliOptions): Integer;
function RunHtml(const o: TCliOptions): Integer;
function RunJson(const o: TCliOptions): Integer;
function RunCreate(const o: TCliOptions): Integer;
function RunServe(const o: TCliOptions): Integer;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  cliutils, clihelp, http, serve;

const
  SeverityNames: array[TAbSeverity] of string = ('Info', 'Warning', 'Error');

function ExitCodeFor(r: TAbResult): Integer;
begin
  case r of
    abOK: result := 0;
    abNoInvoice, abUnknownFormat, abBrokenPDF, abBrokenXML, abInvalidData: result := 1;
  else
    result := 2;
  end;
end;

procedure PrintMessages(var f: Text; const Msgs: TAbMessages);
var
  i: Integer;
begin
  for i := 0 to High(Msgs) do begin
    if Msgs[i].Origin = aboExtra then begin
      Writeln(f, '  [', SeverityNames[Msgs[i].Severity], '] ', Msgs[i].Code, ' (extra check): ', Msgs[i].Text);
    end else begin
      Writeln(f, '  [', SeverityNames[Msgs[i].Severity], '] ', Msgs[i].Code, ': ', Msgs[i].Text);
    end;
  end;
end;

procedure PrintInfoText(const Name: string; r: TAbResult; const Info: TEInvoiceInfo; const Msgs: TAbMessages);
var
  s: string;
  i: Integer;
begin
  PrintField('File', Name);

  case Info.Container of
    eicontPDF:
      begin
        s := 'PDF ' + Info.PDFVersion;

        if Info.PDFAPart <> '' then begin
          s := s + ', PDF/A-' + Info.PDFAPart + LowerCase(Info.PDFAConformance);
        end;

        PrintField('Container', s);
      end;
    eicontXML: PrintField('Container', 'XML');
  end;

  if Info.Syntax <> eisynUnknown then begin
    PrintField('Invoice file', Info.InvoiceFileName);
    PrintField('Syntax', TAbdecker.SyntaxName(Info.Syntax));
    s := TAbdecker.ProfileName(Info.Profile);
    if Info.XRechnungVersion <> '' then s := s + ' ' + Info.XRechnungVersion;
    PrintField('Profile', s);
    PrintField('Guideline ID', Info.GuidelineID);
    PrintField('Invoice number', Info.InvoiceNumber);
    PrintField('Issue date', Info.IssueDate);
    s := Info.TypeCode;

    if TAbdecker.TypeCodeName(Info.TypeCode) <> '' then begin
      s := s + ' (' + TAbdecker.TypeCodeName(Info.TypeCode) + ')';
    end;

    PrintField('Type', s);
    PrintField('Seller', Info.SellerName);
    PrintField('Buyer', Info.BuyerName);

    if Info.GrandTotal <> '' then begin
      PrintField('Grand total', Info.GrandTotal + ' ' + Info.Currency);
    end;

    if Info.DuePayable <> '' then begin
      PrintField('Amount due', Info.DuePayable + ' ' + Info.Currency);
    end;
  end;

  if Length(Info.Attachments) > 0 then begin
    Writeln('Attachments in the PDF:');

    for i := 0 to High(Info.Attachments) do begin
      s := '  ' + Info.Attachments[i].Name;
      if Info.Attachments[i].MimeType <> '' then s := s + '  ' + Info.Attachments[i].MimeType;

      if Info.Attachments[i].Relationship <> '' then begin
        s := s + '  ' + Info.Attachments[i].Relationship;
      end;

      if Info.Attachments[i].Size >= 0 then s := s + '  ' + SizeText(Info.Attachments[i].Size);
      Writeln(s);
    end;
  end;

  if Length(Msgs) > 0 then begin
    Writeln('Messages:');
    PrintMessages(Output, Msgs);
  end;

  PrintField('Result', TAbdecker.ResultText(r));
end;

function RunInfo(const o: TCliOptions): Integer;
var
  data: TBytes;
  info: TEInvoiceInfo;
  msgs: TAbMessages;
  r: TAbResult;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('info'));
  end;

  if not ReadInput(o.Positional[0], data) then exit(2);
  r := TAbdecker.InfoFromBytes(data, info, msgs);

  if o.Json then begin
    Writeln(TAbdecker.InfoToJson(o.Positional[0], r, info, msgs));
  end else begin
    PrintInfoText(o.Positional[0], r, info, msgs);
  end;

  result := ExitCodeFor(r);
end;

{ check -v: the rules by status, IDs wrapped to 79 columns; * = extra check }
procedure PrintRules(const Rep: TAbCheckReport);
const
  Labels: array[TAbRuleStatus] of string = ('not applied', 'passed', 'failed');
  Order: array[0..2] of TAbRuleStatus = (arsFailed, arsPassed, arsNotApplied);
var
  counts: array[TAbRuleStatus] of Integer;
  st: TAbRuleStatus;
  i, k: Integer;
  line, id: string;
  extra: Boolean;
begin
  Writeln;

  if Length(Rep.Rules) = 0 then begin
    Writeln('Rule status: no rule set applied');
    exit;
  end;

  for st := Low(TAbRuleStatus) to High(TAbRuleStatus) do begin
    counts[st] := 0;
  end;

  extra := false;

  for i := 0 to High(Rep.Rules) do begin
    Inc(counts[Rep.Rules[i].Status]);
    if (Rep.Rules[i].Origin = aboExtra) and (Rep.Rules[i].Status <> arsNotApplied) then extra := true;
  end;

  Writeln(Format('Rule status: %d passed, %d failed, %d not applied',
    [counts[arsPassed], counts[arsFailed], counts[arsNotApplied]]));

  for k := 0 to High(Order) do begin
    st := Order[k];
    if counts[st] = 0 then continue;
    line := '  ' + Format('%-13s', [Labels[st]]);

    for i := 0 to High(Rep.Rules) do begin
      if Rep.Rules[i].Status <> st then continue;
      id := Rep.Rules[i].ID;
      if (Rep.Rules[i].Origin = aboExtra) and (st <> arsNotApplied) then id := id + '*';

      if (Length(line) > 15) and (Length(line) + 1 + Length(id) > 79) then begin
        Writeln(line);
        line := StringOfChar(' ', 15);
      end;

      if Length(line) > 15 then line := line + ' ';
      line := line + id;
    end;

    Writeln(line);
  end;

  if extra then Writeln('  * extra check (beyond its rule set)');
end;

procedure PrintCheckText(const Name: string; r: TAbResult; const Inv: TEInvoice;
  const Rep: TAbCheckReport; Verbose: Boolean);
var
  i: Integer;
  s: string;
begin
  PrintField('File', Name);

  if r = abOK then begin
    s := TAbdecker.ProfileName(Inv.Info.Profile);
    if Inv.Info.XRechnungVersion <> '' then s := s + ' ' + Inv.Info.XRechnungVersion;
    PrintField('Profile', s + ' (' + TAbdecker.SyntaxName(Inv.Info.Syntax) + ')');
    PrintField('Invoice', Inv.Number);
    s := '';

    for i := 0 to High(Rep.RuleSets) do begin
      if s <> '' then s := s + ', ';
      s := s + Rep.RuleSets[i];
    end;

    if s = '' then s := '-';
    PrintField('Rules', s);
  end;

  if Length(Rep.Messages) > 0 then begin
    Writeln;
    Writeln('Messages:');
    PrintMessages(Output, Rep.Messages);
  end;

  if r <> abOK then begin
    Writeln;
    PrintField('Result', TAbdecker.ResultText(r));
    exit;
  end;

  if Length(Rep.NotChecked) > 0 then begin
    Writeln;
    Writeln('This invoice contains things that cannot be checked:');

    for i := 0 to High(Rep.NotChecked) do begin
      Writeln('  - ', Rep.NotChecked[i]);
    end;
  end;

  if Verbose then PrintRules(Rep);
  Writeln;

  if Rep.Errors > 0 then begin
    Writeln(Format('Result: %d error(s), %d warning(s)', [Rep.Errors, Rep.Warnings]));
  end else if Length(Rep.NotChecked) > 0 then begin
    if Rep.Warnings > 0 then begin
      Writeln(Format('Everything else was checked: no errors, %d warning(s).', [Rep.Warnings]));
    end else begin
      Writeln('Everything else was checked and is OK.');
    end;
  end else if Rep.Warnings > 0 then begin
    Writeln(Format('Result: no errors, %d warning(s)', [Rep.Warnings]));
  end else begin
    Writeln('Result: checked, OK');
  end;
end;

function RunCheck(const o: TCliOptions): Integer;
var
  data: TBytes;
  inv: TEInvoice;
  rep: TAbCheckReport;
  r: TAbResult;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('check'));
  end;

  if not ReadInput(o.Positional[0], data) then exit(2);
  r := TAbdecker.CheckBytes(data, inv, rep);

  if o.Json then begin
    Writeln(TAbdecker.CheckToJson(o.Positional[0], r, inv, rep, o.Verbose));
  end else begin
    PrintCheckText(o.Positional[0], r, inv, rep, o.Verbose);
  end;

  if r <> abOK then begin
    result := ExitCodeFor(r);
  end else if rep.Failed(abError) then begin
    result := 1;
  end else if rep.Failed(o.FailOn) then begin
    if not o.Json then begin
      Writeln('Failed: warnings count as failure (--fail-on warning).');
    end;

    result := 1;
  end else begin
    result := 0;
  end;
end;

{ A PDF on the console is garbage and can mess up the terminal. Like curl:
  refused unless standard output was asked for explicitly with -o -. }
function PdfTargetOK(const o: TCliOptions; const Target: string): Boolean;
begin
  result := (Target <> '-') or (o.Output = '-') or not StdoutIsConsole;
  if not result then begin
    Writeln(ErrOutput, 'Error: not writing a PDF to the console; use -o <output.pdf>, ' +
      'redirect the output, or force it with -o -');
  end;
end;

function RunEmbed(const o: TCliOptions): Integer;
var
  pdf, xml, res: TBytes;
  msgs: TAbMessages;
  r: TAbResult;
  target: string;
begin
  if Length(o.Positional) <> 2 then begin
    exit(UsageError('embed'));
  end;

  if (o.Positional[0] = '-') and (o.Positional[1] = '-') then begin
    Writeln(ErrOutput, 'Error: only one of the two inputs can be standard input');
    exit(2);
  end;

  if not ReadInput(o.Positional[0], pdf) or not ReadInput(o.Positional[1], xml) then exit(2);
  // standard output unless -o names a file
  target := o.Output;
  if target = '' then target := '-';
  if not PdfTargetOK(o, target) then exit(2);

  if (target <> '-') and FileExists(target) and not o.Force then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  r := TAbdecker.EmbedBytes(pdf, xml, res, msgs);
  PrintMessages(ErrOutput, msgs);

  if r <> abOK then begin
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    if r in [abUnsupported, abNoInvoice, abUnknownFormat, abBrokenXML] then exit(1);
    exit(ExitCodeFor(r));
  end;

  if not WriteOutput(target, res) then exit(2);

  if target <> '-' then begin
    Writeln('Saved as ', target);
  end;

  result := 0;
end;

function RunHtml(const o: TCliOptions): Integer;
var
  data: TBytes;
  inv: TEInvoice;
  msgs: TAbMessages;
  r: TAbResult;
  target, html, lang: string;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('html'));
  end;

  if not ReadInput(o.Positional[0], data) then exit(2);
  r := TAbdecker.LoadFromBytes(data, inv, msgs);
  PrintMessages(ErrOutput, msgs);

  if r <> abOK then begin
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    exit(ExitCodeFor(r));
  end;

  lang := o.Lang;
  if lang = '' then lang := 'de';
  html := TAbdecker.ToHtml(inv, lang, not o.NoCheck, o.Payment);
  // standard output unless -o names a file; --open needs a file: temp folder
  target := o.Output;
  if target = '' then begin
    if o.Open then begin
      if o.Positional[0] = '-' then begin
        target := 'stdin';
      end else begin
        target := ExtractFileName(o.Positional[0]);
      end;

      target := TempFolder + 'abdecker-' + ChangeFileExt(target, '.html');
    end else begin
      target := '-';
    end;
  end;

  if (target <> '-') and FileExists(target) and not o.Force and not (o.Open and (o.Output = '')) then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  if not WriteOutput(target, Utf8Bytes(html)) then exit(2);

  if target <> '-' then begin
    Writeln('Saved as ', target);

    if o.Open and not OpenWithSystem(target) then begin
      Writeln(ErrOutput, 'The file could not be opened automatically.');
    end;
  end;

  result := 0;
end;

{ The JSON goes to the output in any case, on failure with the result code
  and the messages (like check --json); the exit code tells. }
function RunJson(const o: TCliOptions): Integer;
var
  data: TBytes;
  inv: TEInvoice;
  msgs: TAbMessages;
  r: TAbResult;
  target: string;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('json'));
  end;

  if not ReadInput(o.Positional[0], data) then exit(2);
  target := o.Output;
  if target = '' then target := '-';

  if (target <> '-') and FileExists(target) and not o.Force then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  r := TAbdecker.LoadFromBytes(data, inv, msgs);
  if not WriteOutput(target, Utf8Bytes(TAbdecker.InvoiceToJson(o.Positional[0], r, inv, msgs) + #10)) then exit(2);

  if target <> '-' then begin
    Writeln('Saved as ', target);
  end;

  result := ExitCodeFor(r);
end;

function RunExtract(const o: TCliOptions): Integer;
var
  data, xml: TBytes;
  xmlName, target: string;
  msgs: TAbMessages;
  r: TAbResult;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('extract'));
  end;

  if not ReadInput(o.Positional[0], data) then exit(2);
  r := TAbdecker.ExtractXMLFromBytes(data, xml, xmlName, msgs);
  PrintMessages(ErrOutput, msgs);

  if r <> abOK then begin
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    exit(ExitCodeFor(r));
  end;
  // standard output unless -o names a file
  target := o.Output;
  if target = '' then target := '-';

  if (target <> '-') and FileExists(target) and not o.Force then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  if not WriteOutput(target, xml) then exit(2);

  if target <> '-' then begin
    Writeln('"', xmlName, '" saved as ', target);
  end;

  result := 0;
end;

function RunStrip(const o: TCliOptions): Integer;
var
  pdf, res: TBytes;
  msgs: TAbMessages;
  r: TAbResult;
  target, xmlName: string;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('strip'));
  end;

  if not ReadInput(o.Positional[0], pdf) then exit(2);
  // standard output unless -o names a file
  target := o.Output;
  if target = '' then target := '-';
  if not PdfTargetOK(o, target) then exit(2);

  if (target <> '-') and FileExists(target) and not o.Force then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  r := TAbdecker.StripBytes(pdf, res, xmlName, msgs);
  PrintMessages(ErrOutput, msgs);

  if r <> abOK then begin
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    if r = abUnsupported then exit(1);
    exit(ExitCodeFor(r));
  end;

  if not WriteOutput(target, res) then exit(2);

  if target <> '-' then begin
    Writeln('"', xmlName, '" removed, saved as ', target);
  end;

  result := 0;
end;

function RunAttach(const o: TCliOptions): Integer;
var
  xml, res: TBytes;
  docs: TEInvoiceDocuments;
  msgs: TAbMessages;
  r: TAbResult;
  target: string;
  i: Integer;
begin
  if Length(o.Positional) < 2 then begin
    exit(UsageError('attach'));
  end;

  for i := 1 to High(o.Positional) do begin
    if o.Positional[i] = '-' then begin
      Writeln(ErrOutput, 'Error: only the invoice XML can be read from standard input');
      exit(2);
    end;
  end;

  if not ReadInput(o.Positional[0], xml) then exit(2);
  SetLength(docs, Length(o.Positional) - 1);

  for i := 1 to High(o.Positional) do begin
    docs[i - 1] := Default(TEInvoiceDocument);
    docs[i - 1].FileName := o.Positional[i];  // AttachBytes drops the path
    if not ReadInput(o.Positional[i], docs[i - 1].Content) then exit(2);
  end;
  // standard output unless -o names a file
  target := o.Output;
  if target = '' then target := '-';

  if (target <> '-') and FileExists(target) and not o.Force then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  r := TAbdecker.AttachBytes(xml, docs, res, msgs);
  PrintMessages(ErrOutput, msgs);

  if r <> abOK then begin
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    if r = abUnsupported then exit(1);
    exit(ExitCodeFor(r));
  end;

  if not WriteOutput(target, res) then exit(2);

  if target <> '-' then begin
    Writeln(Length(docs), ' file(s) attached, saved as ', target);
  end;

  result := 0;
end;

const
  SourceNames: array[TEInvoiceFileSource] of string = ('pdf', 'invoice');

function ExtForMime(const Mime: string): string;
var
  m: string;
begin
  m := LowerCase(Mime);
  if m = 'application/pdf' then begin
    result := '.pdf';
  end else if m = 'image/png' then begin
    result := '.png';
  end else if m = 'image/jpeg' then begin
    result := '.jpg';
  end else if m = 'text/csv' then begin
    result := '.csv';
  end else if m = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' then begin
    result := '.xlsx';
  end else if m = 'application/vnd.oasis.opendocument.spreadsheet' then begin
    result := '.ods';
  end else if (m = 'text/xml') or (m = 'application/xml') then begin
    result := '.xml';
  end else begin
    result := '.bin';
  end;
end;

type
  TNames = array of string;

{ File names for saving: safe, with an extension, unique (name-2.pdf ...) }
function SaveNames(const Files: TEInvoiceFiles): TNames;
var
  i, j, k: Integer;
  base, ext, n: string;
  taken: Boolean;
begin
  SetLength(result, Length(Files));

  for i := 0 to High(Files) do begin
    n := Files[i].Name;
    if n = '' then n := Files[i].ID;
    n := SafeFileName(n, 'attachment-' + IntToStr(i + 1));
    if ExtractFileExt(n) = '' then n := n + ExtForMime(Files[i].MimeType);
    base := ChangeFileExt(n, '');
    ext := ExtractFileExt(n);
    k := 1;

    repeat
      taken := false;

      for j := 0 to i - 1 do begin
        if SameText(result[j], n) then taken := true;
      end;

      if taken then begin
        Inc(k);
        n := base + '-' + IntToStr(k) + ext;
      end;
    until not taken;

    result[i] := n;
  end;
end;

procedure PrintAttachmentsText(const Name: string; r: TAbResult; const Files: TEInvoiceFiles;
  const Msgs: TAbMessages);
var
  i: Integer;
  f: TEInvoiceFile;
  s: string;
begin
  PrintField('File', Name);

  if r = abOK then begin
    PrintField('Attachments', IntToStr(Length(Files)));

    for i := 0 to High(Files) do begin
      f := Files[i];
      s := '  ' + IntToStr(i + 1) + ' [' + SourceNames[f.Source] + '] ';

      if f.Name <> '' then begin
        s := s + f.Name;
      end else begin
        s := s + '(ID ' + f.ID + ')';
      end;

      if f.MimeType <> '' then s := s + '  ' + f.MimeType;

      if f.URI <> '' then begin
        s := s + '  reference: ' + f.URI;
      end else if Length(f.Content) = 0 then begin
        s := s + '  (no content)';
      end else begin
        s := s + '  ' + SizeText(Length(f.Content));
      end;

      if f.IsInvoice then s := s + '  (the invoice XML)';
      if f.Relationship <> '' then s := s + '  ' + f.Relationship;
      if f.Description <> '' then s := s + '  "' + f.Description + '"';
      Writeln(s);
    end;
  end;

  if Length(Msgs) > 0 then begin
    Writeln('Messages:');
    PrintMessages(Output, Msgs);
  end;

  if r <> abOK then begin
    PrintField('Result', TAbdecker.ResultText(r));
  end;
end;

{ attachments --index: one file to -o or standard output }
function SaveAttachment(const o: TCliOptions; r: TAbResult; const Files: TEInvoiceFiles;
  const Msgs: TAbMessages): Integer;
var
  f: TEInvoiceFile;
  target: string;
begin
  PrintMessages(ErrOutput, Msgs);

  if r <> abOK then begin
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    exit(ExitCodeFor(r));
  end;

  if o.Index > Length(Files) then begin
    Writeln(ErrOutput, 'Error: there is no attachment ', o.Index, ' (attachments: ', Length(Files), ')');
    exit(1);
  end;

  f := Files[o.Index - 1];

  if f.URI <> '' then begin
    Writeln(ErrOutput, 'Error: attachment ', o.Index, ' is only a reference (', f.URI, ')');
    exit(1);
  end;

  if Length(f.Content) = 0 then begin
    Writeln(ErrOutput, 'Error: attachment ', o.Index, ' has no content');
    exit(1);
  end;
  // standard output unless -o names a file; not to the console (see PdfTargetOK)
  target := o.Output;
  if target = '' then target := '-';

  if (target = '-') and (o.Output <> '-') and StdoutIsConsole then begin
    Writeln(ErrOutput, 'Error: not writing an attachment to the console; use -o <file>, ' +
      'redirect the output, or force it with -o -');
    exit(2);
  end;

  if (target <> '-') and FileExists(target) and not o.Force then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  if not WriteOutput(target, f.Content) then exit(2);

  if target <> '-' then begin
    Writeln('Saved ', target, '  ', SizeText(Length(f.Content)));
  end;

  result := 0;
end;

function RunAttachments(const o: TCliOptions): Integer;
var
  data: TBytes;
  files: TEInvoiceFiles;
  msgs: TAbMessages;
  r: TAbResult;
  names: TNames;
  dir: string;
  i: Integer;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('attachments'));
  end;

  if (o.Index > 0) and o.Json then begin
    Writeln(ErrOutput, 'Error: --index cannot be combined with --json');
    exit(2);
  end;

  if (o.Output = '-') and (o.Index = 0) then begin
    Writeln(ErrOutput, 'Error: -o needs a folder for the attachments');
    exit(2);
  end;

  if not ReadInput(o.Positional[0], data) then exit(2);
  r := TAbdecker.AttachmentsFromBytes(data, files, msgs);
  if o.Index > 0 then exit(SaveAttachment(o, r, files, msgs));

  if o.Output = '' then begin
    if o.Json then begin
      Writeln(TAbdecker.AttachmentsToJson(o.Positional[0], r, files, msgs));
    end else begin
      PrintAttachmentsText(o.Positional[0], r, files, msgs);
    end;

    exit(ExitCodeFor(r));
  end;

  // -o: save into the folder
  if r <> abOK then begin
    PrintMessages(ErrOutput, msgs);
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    exit(ExitCodeFor(r));
  end;

  dir := IncludeTrailingPathDelimiter(o.Output);
  names := SaveNames(files);

  if not o.Force then begin
    for i := 0 to High(files) do begin
      if (Length(files[i].Content) > 0) and FileExists(dir + names[i]) then begin
        Writeln(ErrOutput, 'Error: "', dir + names[i], '" already exists (use -f to overwrite)');
        exit(2);
      end;
    end;
  end;

  if not ForceDirectories(dir) then begin
    Writeln(ErrOutput, 'Error: folder "', o.Output, '" cannot be created');
    exit(2);
  end;

  PrintMessages(ErrOutput, msgs);

  for i := 0 to High(files) do begin
    if files[i].URI <> '' then begin
      Writeln(ErrOutput, 'Not saved: "', names[i], '" is only a reference (', files[i].URI, ')');
    end else if Length(files[i].Content) = 0 then begin
      Writeln(ErrOutput, 'Not saved: "', names[i], '" has no content');
    end else begin
      if not WriteOutput(dir + names[i], files[i].Content) then exit(2);

      if not o.Json then begin
        Writeln('Saved ', dir + names[i], '  ', SizeText(Length(files[i].Content)));
      end;
    end;
  end;

  if o.Json then begin
    Writeln(TAbdecker.AttachmentsToJson(o.Positional[0], r, files, msgs));
  end;

  result := 0;
end;

function RunCreate(const o: TCliOptions): Integer;
var
  json, data, xml: TBytes;
  opt: TAbJsonOptions;
  fileVars: TAbStrings;
  inv: TEInvoice;
  msgs: TAbMessages;
  rep: TAbCheckReport;
  r: TAbResult;
  target: string;
  i: Integer;
begin
  if Length(o.Positional) <> 1 then begin
    exit(UsageError('create'));
  end;

  if (o.Positional[0] = '-') and (o.VarsFile = '-') then begin
    Writeln(ErrOutput, 'Error: only one of the two inputs can be standard input');
    exit(2);
  end;

  if not ReadInput(o.Positional[0], json) then exit(2);
  opt := Default(TAbJsonOptions);
  // --var first: the first value of a name counts
  SetLength(opt.Vars, Length(o.Vars));

  for i := 0 to High(o.Vars) do begin
    opt.Vars[i] := o.Vars[i];
  end;

  if o.VarsFile <> '' then begin
    if not ReadInput(o.VarsFile, data) then exit(2);
    r := TAbdecker.VarsFromJson(data, fileVars, msgs);

    if r <> abOK then begin
      PrintMessages(ErrOutput, msgs);
      Writeln(ErrOutput, o.VarsFile, ': ', TAbdecker.ResultText(r));
      exit(ExitCodeFor(r));
    end;

    opt.Vars := Concat(opt.Vars, fileVars);
  end;

  // attachments given as "file" are relative to the JSON file
  if o.Positional[0] = '-' then begin
    opt.BaseDir := GetCurrentDir;
  end else begin
    opt.BaseDir := ExtractFilePath(ExpandFileName(o.Positional[0]));
  end;

  // standard output unless -o names a file
  target := o.Output;
  if target = '' then target := '-';

  if (target <> '-') and FileExists(target) and not o.Force then begin
    Writeln(ErrOutput, 'Error: "', target, '" already exists (use -f to overwrite)');
    exit(2);
  end;

  r := TAbdecker.InvoiceFromJson(json, opt, inv, msgs);

  if r <> abOK then begin
    PrintMessages(ErrOutput, msgs);
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    exit(ExitCodeFor(r));
  end;

  // the XML comes even with check findings; they decide the exit code
  r := TAbdecker.WriteCII(inv, xml, rep);
  PrintMessages(ErrOutput, rep.Messages);

  if r <> abOK then begin
    Writeln(ErrOutput, TAbdecker.ResultText(r));
    if r = abUnsupported then exit(1);
    exit(ExitCodeFor(r));
  end;

  if not WriteOutput(target, xml) then exit(2);

  if target <> '-' then begin
    Writeln('Saved as ', target);
  end;

  if rep.Failed(o.FailOn) then begin
    Writeln(ErrOutput, Format('Check: %d error(s), %d warning(s)', [rep.Errors, rep.Warnings]));
    result := 1;
  end else begin
    result := 0;
  end;
end;

function RunServe(const o: TCliOptions): Integer;
var
  h: THttpOptions;
begin
  if Length(o.Positional) <> 0 then begin
    exit(UsageError('serve'));
  end;

  h := Default(THttpOptions);
  h.Host := o.Host;
  if h.Host = '' then h.Host := '127.0.0.1';
  h.Port := o.Port;
  if h.Port = 0 then h.Port := 8080;
  h.MaxBody := Int64(o.MaxSize) * 1024 * 1024;
  if h.MaxBody = 0 then h.MaxBody := 50 * 1024 * 1024;
  h.Workers := o.Workers;
  if h.Workers = 0 then h.Workers := DefaultWorkers;
  h.QueueSize := o.Queue;
  if h.QueueSize = 0 then h.QueueSize := 4 * h.Workers;
  h.TimeoutMs := o.Timeout * 1000;
  if h.TimeoutMs = 0 then h.TimeoutMs := 30000;
  h.Log := not o.Quiet;
  result := RunServer(h, o.TestRoutes);
end;

end.
