/**
 * ABL Language Server implementation
 *
 * This source code is not part of an open-source package.
 * Copyright (c) 2021-2026 Riverside Software
 * contact@riverside-software.fr
 */
&scoped-define TIMEOUT 180

&scoped-define MAJOR INTEGER(SUBSTRING(PROVERSION, 1, INDEX(PROVERSION, '.') - 1))
&scoped-define MAJOR_SZ LENGTH({&MAJOR})

&scoped-define PROVERSION_MINOR SUBSTRING(PROVERSION(1), {&MAJOR_SZ} + 2)
&scoped-define MINOR INTEGER(SUBSTRING({&PROVERSION_MINOR}, 1, INDEX({&PROVERSION_MINOR}, '.') - 1))
&scoped-define MINOR_SZ LENGTH({&MINOR})

&scoped-define PROVERSION_PATH SUBSTRING(PROVERSION(1), {&MAJOR_SZ} + {&MINOR_SZ} + 3)
&scoped-define PATCH INTEGER(SUBSTRING({&PROVERSION_PATH}, 1, INDEX({&PROVERSION_PATH}, '.') - 1))

&if ({&MAJOR} ge 11) &then
block-level on error undo, throw.
&endif

using Progress.Json.ObjectModel.JsonArray.
using Progress.Json.ObjectModel.JsonObject.
using Progress.Json.ObjectModel.ObjectModelParser.

define temp-table ttMsgs no-undo
  field msgNum  as integer
  field level   as integer
  field msgLine as character
  index ttMsgsPK is primary unique msgNum.

/* https://learn.microsoft.com/fr-fr/windows/win32/api/winuser/nf-winuser-findwindowa */
procedure FindWindowA external "user32.dll":
  define input  parameter lpFileName as long.      /* LPCSTR lpClassName */
  define input  parameter dwAccess   as character. /* LPCSTR lpWindowName */
  define return parameter dwHandle   as long.
end procedure.

/* https://learn.microsoft.com/fr-fr/windows/win32/api/winuser/nf-winuser-showwindow */
procedure ShowWindow external "user32.dll":
  define input  parameter hWnd     as int64. /* HWND hWnd */
  define input  parameter nCmdShow as short. /* int  nCmdShow */
  define return parameter bool     as long.
end procedure.

define new shared stream WebStream.

define variable jsonParser as ObjectModelParser no-undo.
define variable configJson as JsonObject        no-undo.
define variable ppEntries  as JsonArray         no-undo.
define variable dbEntries  as JsonArray         no-undo.
define variable procEntries as JsonArray         no-undo.
define variable dbEntry    as JsonObject        no-undo.
define variable procEntry  as JsonObject        no-undo.

define variable zz  as integer     no-undo.
define variable zz2 as integer     no-undo.
define variable i   as integer     no-undo.
define variable hP  as handle      no-undo.

define variable hostName     as character   no-undo.
define variable portNumber   as integer     no-undo.
define variable threadNumber as integer     no-undo.

define variable lQuitRcvd  as logical no-undo.
define variable hSocket    as handle  no-undo.
define variable aOk        as logical no-undo.
define variable aResp      as logical no-undo.
define variable currentMsg as integer no-undo.
define variable wGuid      as character no-undo.
define variable hWnd       as int64   no-undo.

log-manager:write-message(substitute("Version: &4 - Internal codepage: &1 - Stream codepage: &2 - Startup parameters: &3", session:cpinternal, session:cpstream, session:startup-parameters, proversion)).

compiler:multi-compile = true.
assign jsonParser = new ObjectModelParser().
assign configJson = cast(jsonParser:ParseFile(session:parameter), JsonObject).

assign hostName = configJson:GetCharacter("hostName").
assign portNumber = configJson:GetInteger("portNumber").
assign threadNumber = configJson:GetInteger("threadNumber").

if configJson:GetLogical("hideWindow") and session:display-type = 'GUI' and opsys = 'WIN32' then do:
&if ({&MAJOR} ge 11) and (process-architecture = 64) &then
  wGuid = substitute("P&1T&2U&3", portNumber, threadNumber, guid).
  default-window:title = wGuid.
  run FindWindowA(0, wGuid, output hWnd).
  if (hWnd <> 0) then do:
    run ShowWindow(hWnd, 0, output zz).
    log-manager:write-message("Hiding default window: " + (if zz <> 0 then "success" else "failure (or already hidden)")).
  end.
&endif
end.

/* Init procedures only */
if (configJson:has("procedures")) then do:
  assign procEntries = configJson:GetJsonArray("procedures").
  do zz = 1 to procEntries:Length:
    assign procEntry = procEntries:GetJsonObject(zz).
    if (procEntry:has("name") and procEntry:has("mode") and procEntry:getCharacter("mode") eq "init") then do:
      log-manager:write-message(substitute("Execute init procedure: &1", procEntry:getCharacter("name"))).
      run value(procEntry:getCharacter("name")).
    end.
  end.
end.

/* DB connections + aliases */
assign dbEntries = configJson:GetJsonArray("databases").
do zz = 1 to dbEntries:Length:
  assign dbEntry = dbEntries:GetJsonObject(zz).
  if (dbEntry:has("name") and dbEntry:has("connect")) then do:
    log-manager:write-message(substitute("Connecting to DB '&1': '&2'", dbEntry:GetCharacter("name"), dbEntry:GetCharacter("connect"))).
    connect value(dbEntry:GetCharacter("connect")) no-error.
    if error-status:error then do:
      if (error-status:num-messages > 1) or (error-status:get-number(1) ne 1552) then do:
        log-manager:write-message(substitute("Unable to connect to '&1'" , dbEntry:GetCharacter("name"))).
        do i = 1 to error-status:num-messages:
          log-manager:write-message(error-status:get-message(i)).
        end.
&IF ({&MAJOR} GE 12) OR (({&MAJOR} EQ 11 ) AND ({&MINOR} EQ 7) AND ({&PATCH} GE 3)) &THEN
        session:exit-code = 10.
&ENDIF
        quit.
      end.
    end.
    if (dbEntry:has("aliases")) then do:
      do zz2 = 1 to dbEntry:GetJsonArray("aliases"):length:
        log-manager:write-message(substitute("Create alias '&1' for '&2'", dbEntry:GetJsonArray("aliases"):GetCharacter(zz2), dbEntry:GetCharacter("name"))).
        create alias value(dbEntry:GetJsonArray("aliases"):GetCharacter(zz2)) for database value(dbEntry:GetCharacter("name")).
      end.
    end.
  end.
end.

/* PROPATH entries */
assign ppEntries = configJson:GetJsonArray("propath").
do zz = 1 to ppEntries:Length:
  assign propath = ppEntries:getCharacter(ppEntries:Length + 1 - zz) + "," + propath.
end.
log-manager:write-message("PROPATH: " + propath).

/* Once, persistent and super procedures */
if (configJson:has("procedures")) then do:
  assign procEntries = configJson:GetJsonArray("procedures").
  do zz = 1 to procEntries:Length:
    assign procEntry = procEntries:GetJsonObject(zz).
    if (procEntry:has("name") and procEntry:has("mode") and procEntry:getCharacter("mode") ne "init") then do:
      if (procEntry:getCharacter("mode") eq "once") then do:
        log-manager:write-message(substitute("RunOnce '&1'", procEntry:getCharacter("name"))).
        run value(procEntry:getCharacter("name")).
      end.
      else if (procEntry:getCharacter("mode") eq "persistent") then do:
        log-manager:write-message(substitute("RunPersistent '&1'", procEntry:getCharacter("name"))).
        run value(procEntry:getCharacter("name")) persistent.
      end.
      else if (procEntry:getCharacter("mode") eq "super") then do:
        log-manager:write-message(substitute("RunSuper '&1'", procEntry:getCharacter("name"))).
        run value(procEntry:getCharacter("name")) persistent set hP.
        session:add-super-procedure(hP).
      end.
    end.
  end.
end.

create socket hSocket.
run ConnectToServer no-error.
/* Loop forever listening for data from the server */
/* Leave loop after 180 seconds without any message */
EternalLoop:
do while aOk:
  if valid-handle(hSocket) then do:
    assign aResp = false.
    wait-for read-response of hSocket pause {&TIMEOUT}.
    if not aResp then do:
      log-manager:write-message("No message since {&TIMEOUT} seconds, end of process").
      leave EternalLoop.
    end.
  end.
end.
&IF ({&MAJOR} GE 12) OR (({&MAJOR} EQ 11 ) AND ({&MINOR} EQ 7) AND ({&PATCH} GE 3)) &THEN
if (not lQuitRcvd) then
  session:exit-code = 11.
&ENDIF
quit.

catch err as Progress.Lang.Error:
  log-manager:write-message("Unexpected error...").
  do zz = 1 to err:NumMessages:
    log-manager:write-message(substitute(" &1", err:getMessage(zz))).
  end.
end catch.

procedure ConnectToServer.
  define variable packet       as longchar    no-undo.
  define variable packetBuffer as memptr      no-undo.

  log-manager:write-message(substitute("Connecting to backend on &1:&2 ", hostName, portNumber)).
  assign aOk = hSocket:connect(substitute("-H &1 -S &2", hostName, portNumber)) no-error.
  if not aOk then do:
    return error "Connection to backend failed".
  end.
  else do:
    log-manager:write-message('Connected').
    hSocket:set-read-response-procedure("handleCommand").
    packet = string(threadNumber) + "~n".
    copy-lob from packet to packetBuffer.
    hSocket:write(packetBuffer, 1, get-size(packetBuffer)).
    set-size(packetBuffer) = 0.
  end.

end procedure.

/* Handle writing of response data back to the language server */
/* First line is in this format : */
/* [OK|ERR]:Custom_response */
/* Following lines are in this format */
/* MSG:message_line */
/* Last line is in this format */
/* END */
/* Message lines are read from the ttMsgs temp-table */
/* This temp-table is emptied when a new command is run */
procedure WriteToSocket:
  define input  parameter plOK   as logical   no-undo.
  define input  parameter pcResp as character no-undo.

  define variable packetBuffer as memptr   no-undo.
  define variable packet       as longchar no-undo.

  assign packet = substitute("&1:&2~n", if plOK then "OK" else "ERR", pcResp).
  for each ttMsgs:
    assign packet = packet + substitute("MSG:&1:&2~n", ttMsgs.level, ttMsgs.msgLine).
  end.
  assign packet = packet + "END~n".

  copy-lob from packet to packetBuffer.
  if valid-handle(hSocket) then do:
    if hSocket:connected() then do:
      hSocket:write(packetBuffer, 1, get-size(packetBuffer)).
      set-size(packetBuffer) = 0.
    end.
    else do:
      run Quit("").
    end.
  end.
end procedure.

procedure handleCommand:
  define variable cCmd   as character no-undo.
  define variable i1     as integer   no-undo.
  define variable mBuf   as memptr    no-undo.
  define variable iBytes as integer   no-undo.

  if not self:connected() then do:
    return error "Socket disconnected".
  end.

  assign iBytes = self:get-bytes-available()
         set-size(mBuf) = iBytes
         aOk  = self:read(mBuf, 1, iBytes)
         cCmd = get-string(mBuf, 1, iBytes)
         set-size(mBuf) = 0.
  assign cCmd = replace(cCmd, chr(13), '').  /* Strip CR */
  assign aResp = true.

  /* Check if a full command */
  assign cCmd = (if self:private-data eq ? then "" else self:private-data) + cCmd
         i1   = index(cCmd, chr(10)).

  if not aOk then do:
    apply "close" to this-procedure.
    return error "Something bad happened".
  end.

  if (i1 > 0) then do:
    run executeCmd(trim(substring(cCmd, 1, i1 - 1, 'character'))).
    self:private-data = (if length(cCmd, 'character') gt i1 then substring(cCmd, i1 + 1, -1, 'character') else "").
  end.
  else
    self:private-data = cCmd.

end procedure.

/* If a command was received from backend then process it here and
* call the appropriate procedure */
procedure executeCmd:
  define input parameter cCmd as character no-undo.

  define variable cPrm  as character  no-undo initial "".
  define variable hProc as handle     no-undo.
  define variable idx   as integer    no-undo.
  define variable lOK   as logical    no-undo.
  define variable cMsg  as character  no-undo.

  empty temp-table ttMsgs.

  assign idx = index(cCmd, ' ').
  if (idx ne 0) then do:
    assign cPrm = trim(substring(cCmd, idx + 1, -1, 'character'))
           cCmd = trim(substring(cCmd, 1, idx, 'character')).
  end.

  /* Checks if internal method */
  if (can-do(this-procedure:internal-entries, cCmd)) then do:
    assign hProc = this-procedure.
  end.
  else do:
    /* Checking super procedures */
    assign hProc = session:first-procedure.
    ProcSearch:
    do while (valid-handle(hProc) and not can-do(hProc:internal-entries, cCmd)):
      assign hProc = hProc:next-sibling.
      if (hProc eq ?) then do:
        leave ProcSearch.
      end.
    end.
  end.
  if (hProc eq ?) or (not valid-handle(hProc)) then do:
    run logError ("Unable to execute procedure").
    run writeToSocket(false, "").
    return ''.
  end.

  DontQuit:
  do on error undo, retry on stop undo, retry on endkey undo, retry on quit undo, retry:
    if retry then do:
      assign lOK = false.
      run logError ("Error during execution").
      leave DontQuit.
    end.
    run value(cCmd) in hProc (input cPrm, output lOK, output cMsg).
  end.

  run WriteToSocket(lOK, cMsg).

end procedure.

procedure noOp private:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo initial true.
  define output parameter opMsg as character   no-undo initial "NO-OP".

  publish "noOpEvent" (ipPrm).

end procedure.

procedure compile private:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opCompErr as character   no-undo.

  define variable opError   as logical   no-undo.
  define variable lCanceled as integer   no-undo.
  define variable cMsg      as character no-undo.

  define variable srcFile  as character no-undo.
  define variable buildDir as character no-undo.
  define variable xrefFile  as character no-undo.

  assign srcFile = entry(1, ipPrm, ';')
         buildDir = entry(2, ipPrm, ';')
         xrefFile = entry(3, ipPrm, ';').

  log-manager:write-message(substitute("Compile '&1' into '&2' xref '&3'", srcFile, buildDir, xrefFile)).
  publish "preCompileHook" (srcFile, buildDir, xrefFile, output lCanceled).
  if (lCanceled <> 0) then do:
    opOK = true.
    if (lCanceled = 1) then do:
      opCompErr = "yes". // yes = compilation failed
      assign cMsg = substitute("&1|&2|&3|&4", 0, 0, search(srcFile), "Compilation canceled by pre-compile hook").
      run logWarning(cMsg).
    end.
    else if (lCanceled = 2) then do:
      opCompErr = "yes". // yes = compilation failed
      assign cMsg = substitute("&1|&2|&3|&4", 0, 0, search(srcFile), "Compilation canceled by pre-compile hook").
      run logError(cMsg).
    end.
    else if (lCanceled = 3) then do:
      opCompErr = "hook-no". // no = compilation successful
    end.
    else if (lCanceled = 4) then do:
      opCompErr = "hook-yes". // yes = compilation failed
    end.
    else do:

      log-manager:write-message(substitute("preCompileHook - Unknown cancelation status: &1", lCanceled)).
      opOK = false.
    end.
    return.
  end.

  compile value(srcFile) save into value(buildDir) xref value(xrefFile) no-error.
  opOK = true.
  opCompErr = string(compiler:error, "yes/no").

  assign opError = compiler:error.
  if not opError then do:
    if compiler:warning then do:
      do i = 1 to compiler:num-messages:
        /* Pointless message coming from strict mode compiler */
        if compiler:get-number(i) eq 2411 then next.
        /* Messages 2363, 3619 and 3623 are in fact warnings (from -checkdbe switch) */
        if (compiler:get-message-type(i) eq 2) or (compiler:get-number(i) eq 2363) or (compiler:get-number(i) eq 3619) or (compiler:get-number(i) eq 3623) then do:
          if (lookup(string(compiler:get-number(i)), session:suppress-warnings-list) eq 0) then do:
            run logWarning(substitute("&1|&2|&3|&4", compiler:get-number(i), compiler:get-row(i), compiler:get-file-name(i), replace(compiler:get-message(i), '~n', ' '))).
          end.
        end.
      end.
    end.
  end.
  else do:
    do i = 1 to compiler:num-messages:
      /* Discard pointless "Could not understand line <number>" */
      if compiler:get-number(i) eq 198 then next.
      /* Discard error message 293 on the main file name as these messages can't be removed from the Problems view in VS Code */
      /* Also there's no value in reporting failed compilation attempts */
      if (compiler:get-number(i) eq 293) then do:
        if replace(compiler:get-message(i), '~\', '/') begins substitute("** ~"&1~" ", replace(entry(1, ipPrm, ';'), '~\', '/')) then next.
      end.
      run logError(substitute("&1|&2|&3|&4", compiler:get-number(i), compiler:get-row(i), compiler:get-file-name(i), replace(compiler:get-message(i), '~n', ' '))).
    end.
  end.
  publish "postCompileHook" (srcFile, buildDir, xrefFile).

end procedure.

procedure compileBuffer:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opMsg as character   no-undo.

  define variable opError   as logical  no-undo.
  define variable bIsClass  as logical  no-undo.
  define variable bWrongCls as logical  no-undo.
  define variable clsName   as character no-undo.
  define variable cnt       as integer   no-undo.
  define variable dirName   as character no-undo.
  define variable parentDir as character no-undo.

  log-manager:write-message(substitute("Compile buffer &1", ipPrm)).
  publish "preCompileBufferHook" (ipPrm).
  parentDir = substring(ipPrm, 1, r-index(replace(ipPrm, '~\', '/'), '/'), 'character').

  compile value(ipPrm) save = false no-error.
  /* Such an ugly workaround... But even the procedure editor has to rely on that to compile unnamed buffers */
  /* Error 12622 ? Then rename file with .cls extension and recompile */
  do i = 1 to compiler:num-messages:
    bIsClass = bIsClass or (compiler:get-number(i) eq 12622) or (compiler:get-number(i) eq 12623) or (compiler:get-number(i) eq 17950).
  end.
  if bIsClass then do:
    log-manager:write-message("Append .cls extension to buffer name").
    os-rename value(ipPrm) value(ipPrm + ".cls").
    compile value(ipPrm + ".cls") save = false no-error.
    do i = 1 to compiler:num-messages:
      if (compiler:get-number(i) eq 12629) or (compiler:get-number(i) eq 12855) or (compiler:get-number(i) eq 17951) then do:
        bWrongCls = true.
        /* Name of the class in the CLASS statement 'XXX' must match the pattern of the name of the file '-*-*-.cls'. (12629) */
        clsName = compiler:get-message(i).
        clsName = substring(clsName, index(clsName, "'") + 1, -1, 'character').
        clsName = substring(clsName, 1, index(clsName, "'") - 1, 'character').
      end.
    end.
    if bWrongCls then do:
      do cnt = 1 to num-entries(clsName, '.') - 1:
        dirName = dirName + (if dirName eq '' then '' else '/') + entry(cnt, clsName, '.').
        os-create-dir value(parentDir + dirName).
      end.
      /* Here is the super fun part: there's no need to create directory structure for packages, file name with periods in it is enough to fool the compiler :-D */
      /* Update: for whatever reason, this works for class / interface, but not for enum, so we have to create the directory structure */
      log-manager:write-message("Rename buffer to " + replace(clsName, '.', '/') + ".cls").
      os-rename value(ipPrm + ".cls") value(parentDir + replace(clsName, '.', '/') + ".cls").
      compile value(parentDir + replace(clsName, '.', '/') + ".cls") save = false no-error.
      os-delete value(parentDir + replace(clsName, '.', '/') + ".cls").
    end.
    else
      os-delete value(ipPrm + ".cls").
  end.
  else do:
    os-delete value(ipPrm).
  end.
  opOK = true.
  opMsg = string(compiler:error, "yes/no").
  if (clsName ne '') then do:
    clsName = replace(parentDir + replace(clsName, '.', '/') + ".cls", '~\', '/').
  end.

  assign opError = compiler:error.
  if not opError then do:
    if compiler:warning then do:
      do i = 1 to compiler:num-messages:
        /* Pointless message coming from strict mode compiler */
        if compiler:get-number(i) eq 2411 then next.
        /* Messages 2363, 3619 and 3623 are in fact warnings (from -checkdbe switch) */
        if (compiler:get-message-type(i) eq 2) or (compiler:get-number(i) eq 2363) or (compiler:get-number(i) eq 3619) or (compiler:get-number(i) eq 3623) then do:
          if (lookup(string(compiler:get-number(i)), session:suppress-warnings-list) eq 0) then do:
            run logWarning(substitute("&1|&2|&3|&4", compiler:get-number(i), compiler:get-row(i), if replace(compiler:get-file-name(i), '~\', '/') eq clsName then '__BUFFER__' else replace(compiler:get-file-name(i), '~\', '/'), replace(compiler:get-message(i), '~n', ' '))).
          end.
        end.
      end.
    end.
  end.
  else do:
    do i = 1 to compiler:num-messages:
      if compiler:get-number(i) eq 198 then next.
      run logError(substitute("&1|&2|&3|&4", compiler:get-number(i), compiler:get-row(i), if replace(compiler:get-file-name(i), '~\', '/') eq clsName then '__BUFFER__' else replace(compiler:get-file-name(i), '~\', '/'), replace(compiler:get-message(i), '~n', ' '))).
    end.
  end.
  publish "postCompileBufferHook" (ipPrm).

end procedure.


procedure speedscriptConvert:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opMsg as character   no-undo.

  define variable cOutFile as character no-undo.
  define variable cWsOptions as character no-undo.
  define variable zz as int no-undo.

  assign cOutFile   = entry(2, ipPrm, ';')
         cWsOptions = "".

  log-manager:write-message(substitute("SpeedScript convert '&1' to '&2'", entry(1, ipPrm, ';'), cOutFile)).
  run webutil/e4gl-gen.r (input entry(1, ipPrm, ';'), input-output cWsOptions, input-output cOutFile) no-error.

  if error-status:error then do:
    do zz = 1 to error-status:num-messages:
      log-manager:write-message(substitute("Webspeed error &2: &1", error-status:get-message(zz), error-status:get-number(zz))).
    end.
    opOK = true.
    opMsg = "yes". /* yes = conversion failed */
    run logError(substitute("&1|&2|&3|&4", 0, 1, search(entry(1, ipPrm, ';')), "SpeedScript conversion failed")).
  end.
  else do:
    opOK  = true.
    opMsg = "no". /* no = success */
  end.

end procedure.

procedure preprocess:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opMsg as character   no-undo.

  log-manager:write-message(substitute("Preprocess &1 into &2", entry(1, ipPrm, ';'), entry(2, ipPrm, ';'))).
  compile value(entry(1, ipPrm, ';')) save = false preprocess value(entry(2, ipPrm, ';')) no-error.
  opOK = not compiler:error.
  opMsg = entry(2, ipPrm, ';').

end procedure.

procedure debugListing:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opMsg as character   no-undo.

  log-manager:write-message(substitute("Debug-listing &1 into &2", entry(1, ipPrm, ';'), entry(2, ipPrm, ';'))).
  compile value(entry(1, ipPrm, ';')) save = false debug-list value(entry(2, ipPrm, ';')) no-error.
  opOK = not compiler:error.
  opMsg = entry(2, ipPrm, ';').

end procedure.

procedure listing:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opMsg as character   no-undo.

  log-manager:write-message(substitute("Listing &1 into &2", entry(1, ipPrm, ';'), entry(2, ipPrm, ';'))).
  compile value(entry(1, ipPrm, ';')) save = false listing value(entry(2, ipPrm, ';')) no-error.
  opOK = not compiler:error.
  opMsg = entry(2, ipPrm, ';').

end procedure.

procedure xref:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opMsg as character   no-undo.

  log-manager:write-message(substitute("XREF &1 into &2", entry(1, ipPrm, ';'), entry(2, ipPrm, ';'))).
  compile value(entry(1, ipPrm, ';')) save = false xref value(entry(2, ipPrm, ';')) no-error.
  opOK = not compiler:error.
  opMsg = entry(2, ipPrm, ';').

end procedure.

procedure xmlXref:
  define input  parameter ipPrm as character   no-undo.
  define output parameter opOK  as logical     no-undo.
  define output parameter opMsg as character   no-undo.

  log-manager:write-message(substitute("XML-XREF &1 into &2", entry(1, ipPrm, ';'), entry(2, ipPrm, ';'))).
  compile value(entry(1, ipPrm, ';')) save = false xref-xml value(entry(2, ipPrm, ';')) no-error.
  opOK = not compiler:error.
  opMsg = entry(2, ipPrm, ';').

end procedure.

procedure log private:
  define input  parameter ipMsg as character   no-undo.
  define input  parameter ipLvl as integer     no-undo.

  assign currentMsg = currentMsg + 1.
  create ttMsgs.
  assign ttMsgs.msgNum  = currentMsg
         ttMsgs.level   = ipLvl
         ttMsgs.msgLine = ipMsg.
end procedure.

procedure logError private:
  define input  parameter ipMsg as character   no-undo.
  run log (ipMsg, 0).
end procedure.

procedure logWarning private:
  define input  parameter ipMsg as character   no-undo.
  run log (ipMsg, 1).
end procedure.

procedure logInfo private:
  define input  parameter ipMsg as character   no-undo.
  run log (ipMsg, 2).
end procedure.

procedure logVerbose private:
  define input  parameter ipMsg as character   no-undo.
  run log (ipMsg, 3).
end procedure.

procedure logDebug private:
  define input  parameter ipMsg as character   no-undo.
  run log (ipMsg, 4).
end procedure.

procedure hookWarning:
  define input parameter ipErrNum as integer no-undo.
  define input parameter ipLineNum as integer no-undo.
  define input parameter ipSrcFile as character no-undo.
  define input parameter ipMsg as character no-undo.

  run logWarning (substitute("&1|&2|&3|&4", ipErrNum, ipLineNum, ipSrcFile, ipMsg)).
end procedure.

procedure hookError:
  define input parameter ipErrNum as integer no-undo.
  define input parameter ipLineNum as integer no-undo.
  define input parameter ipSrcFile as character no-undo.
  define input parameter ipMsg as character no-undo.

  run logError (substitute("&1|&2|&3|&4", ipErrNum, ipLineNum, ipSrcFile, ipMsg)).
end procedure.

 /* Commands to be executed from executeCmd */
 /* Each command should have an input param as char (command parameters) and */
 /* an output param as logical, to tell ANT if command was executed successfully or not */


 /* This will terminate the infinite loop of waiting for commands and
  * quit out of the Progress session */
procedure quit:
  define input  parameter cPrm as character no-undo.
  define output parameter opOK as logical     no-undo.
  define output parameter opMsg as character no-undo.

  publish "quitEvent" (cPrm).

  assign opOK = true
         aOk  = false
         lQuitRcvd = true.
  apply "close" to this-procedure.

end procedure.

function getThreadNumber returns integer:
  return threadNumber.
end function.

/* Run a procedure persistently */
procedure launch:
  define input  parameter cPrm as character   no-undo.
  define output parameter opOK as logical     no-undo.
  define output parameter opMsg as character  no-undo.

  run value(cPrm) persistent no-error.
  if error-status:error then do:
    assign opOK = false.
    run logError (error-status:get-message(1)).
  end.
  else do:
    assign opOK = true.
  end.

end procedure.
