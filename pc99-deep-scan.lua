-- =====================================================================
-- PC99 DEEP-SCAN v7 (Delta/Lua)
-- READ-ONLY = keine Klicks, kein Handel, keine Spiel-Interaktion.
-- Der Scanner schreibt EIGENE Report-Dateien, entfernt NUR sein eigenes
-- Alt-Panel (PC99-Name, gestoppte Instanz) und erzeugt ein Diagnose-Panel.
-- v7 = 56-Punkte-Review v6: row.sg-Field (Trade-Root/CLOSED wieder
-- funktional), objCount-Grenze VOR Verarbeitung, append/write-Fehler
-- verlieren keine Daten mehr (Retry + Drop-Zaehler), RUNTIME wird
-- enforce't, Lesefehler nicht mehr als "disabled/hidden" fehldeutbar,
-- containsWord-Grenzen fuer Needles, vorheriger Trade-Root bevorzugt
-- (deterministisch), xpcall-Hauptloop + Flush-Timer + Kompaktmodus.
-- Report: Konsole + pc99_scan7_<HHMMSS>.txt (+ _ascii.txt Spiegel)
-- =====================================================================

local CFG = {
	RUNTIME              = 900,   -- Sekunden, wird ENFORCED (Schleife + Warteschleife)
	SCAN_INTERVAL        = 2,
	MAX_OBJS             = 25000, -- traversierte Objekte je Scan; Grenze wird VOR Verarbeitung geprueft
	BASELINE_PASSES      = 3,
	BASELINE_MIN_MATCH   = 2,     -- aufeinanderfolgende strukturell identische Scans fuer "STABIL"
	BASELINE_WAIT        = 1,
	BASELINE_MAX_WALL    = 60,    -- Sekunden Gesamt-Budget fuer die Baseline (dann letzten gueltigen Pass akzeptieren)
	DIFF_JITTER_SUPPRESS = true,  -- reine pos/size-Aenderungen (Animationen) als Zaehler statt Listing
	REQUIRE_STABLE_BASELINE = false, -- true = ohne stabile Baseline keine Diffs
	PROBE_COOLDOWN       = 1.5,
	MAX_WATCHERS         = 3000,  -- Verbindungen (2 je Textobjekt => ~1500 Textobjekte)
	MAX_ROOT_CONNS       = 300,   -- Root/ScreenGui-Signal-Verbindungen begrenzen
	MAX_CHAIN            = 40,
	MAX_GEOM             = 6,
	MAX_DIFFS_FILE       = 400,   -- danach Kompaktmodus (1 Zeile je Diff)
	MAX_SECT_CHARS       = 16000,
	MAX_BASE_DUMP        = 600,   -- Baseline-Zeilen im Dump (Ausgabemenge; Inhalte je Row vollstaendig)
	MIN_FRAME_W          = 120,
	MIN_FRAME_H          = 80,
	INVENTORY_ALL_FRAMES = false,
	SKIP_EXEC_GUIS       = true,
	SKIP_NAME_PATTERNS   = { "pc99" }, -- eigene GUIs; zusaetzlich Referenz-Ausschluss des Panels
	ASCII_MIRROR         = true,
	PROBE_CLIPBOARD      = false, -- Clipboard wird NICHT angetastet (nicht read-only)
	CONTAINER_RESCAN_EVERY = 25,  -- Scans bis Neusuche von GUI-Containern
	FLUSH_EVERY_S        = 5,     -- Zeit-Flush, damit Crash nicht alles verliert
	BUF_CAP              = 262144, -- Puffer-Grenze bei Schreibfehlern
	BUF_KEEP             = 131072,
}

if getgenv().PC99_SCAN7 and getgenv().PC99_SCAN7.stop then
	pcall(getgenv().PC99_SCAN7.stop)
end

local Players    = game:GetService("Players")
local running    = true
local t0         = os.time()
local startClock = os.clock()
local rootCons   = {}
local watchCons  = {}
local rootConnCount = 0
local rootConnWarned = false

local function nowStr() return os.date("%H:%M:%S") end

local function stopAll()
	running = false
	for _, c in ipairs(rootCons) do pcall(function() c:Disconnect() end) end
	for _, w in ipairs(watchCons) do pcall(function() w.con:Disconnect() end) end
	if getgenv().PC99_SCAN7 then getgenv().PC99_SCAN7.stopped = true end
end
local RUN = { stop = stopAll }
getgenv().PC99_SCAN7 = RUN

-- ---------------------------------------------------------------
-- Datei: Erstwrite bis ERFOLG, danach appendfile. FEHLGESCHLAGENE
-- Bloecke werden NICHT verworfen (Retry naechster Flush); nur bei
-- Buffer-Ueberlauf wird AELTESTES verworfen und als dropped gezaehlt.
-- ---------------------------------------------------------------
local filePath   = "pc99_scan7_" .. os.date("%H%M%S") .. ".txt"
local mirrorPath = "pc99_scan7_" .. os.date("%H%M%S") .. "_ascii.txt"
local fileInit   = false   -- true erst nach ERFOLGREICHEM writefile
local mirrorInit = false
local fileBuf    = ""
local lastFlushClock = os.clock()
local ioStat = {
	wf = "nicht getestet", af = "n/a", rf = "nicht getestet", clip = "deaktiviert (nicht read-only)",
	prot = "nicht getestet", delfile = "nicht getestet",
	gethui = "nicht getestet", gethiddenguis = "nicht getestet",
	writes = 0, appends = 0, wfErr = 0, appendErr = 0, appendErrMsg = "", mirrorErr = 0,
	bytes = 0, dropped = 0,
}

local function bufDropOldest()
	if #fileBuf > CFG.BUF_CAP then
		local drop = #fileBuf - CFG.BUF_KEEP
		fileBuf = string.sub(fileBuf, drop + 1)
		ioStat.dropped = ioStat.dropped + drop
	end
end

local function fileFlush(force)
	if #fileBuf == 0 then return end
	if not fileInit then
		local ok, e = pcall(writefile, filePath, fileBuf)
		if ok then
			fileInit = true
			ioStat.wf = "ok"
			ioStat.writes = ioStat.writes + 1
			ioStat.bytes = ioStat.bytes + #fileBuf
			fileBuf = ""
		else
			ioStat.wfErr = ioStat.wfErr + 1
			ioStat.wf = "FEHLER: " .. tostring(e)
			bufDropOldest() -- Daten bleiben fuer Retry im Puffer
		end
	else
		local ok, e = pcall(appendfile, filePath, fileBuf)
		if ok then
			ioStat.af = "ok"
			ioStat.appends = ioStat.appends + 1
			ioStat.bytes = ioStat.bytes + #fileBuf
			fileBuf = ""
		else
			ioStat.appendErr = ioStat.appendErr + 1
			ioStat.appendErrMsg = tostring(e)
			bufDropOldest() -- Daten bleiben fuer Retry im Puffer
		end
	end
end

-- Eigenstaendiger ASCII-Spiegel mit IDENTISCHER Retry-/Buffer-Semantik
-- wie die Hauptdatei: Fehlgeschlagene Bloecke bleiben im Puffer (Retry),
-- Drop-Cap zaehlt verworfene Bytes (mirrorDropped).
local mirrorDropped = 0
local function mirrorDropOldest()
	if #mirrorBuf > CFG.BUF_CAP then
		local d = #mirrorBuf - CFG.BUF_KEEP
		mirrorBuf = string.sub(mirrorBuf, d + 1)
		mirrorDropped = mirrorDropped + d
	end
end
local function mirrorFlush()
	if not CFG.ASCII_MIRROR or #mirrorBuf == 0 then return end
	if not mirrorInit then
		local ok, e = pcall(writefile, mirrorPath, mirrorBuf)
		if ok then mirrorInit = true; mirrorBuf = ""
		else ioStat.mirrorErr = ioStat.mirrorErr + 1; mirrorDropOldest() end
	else
		local ok = pcall(appendfile, mirrorPath, mirrorBuf)
		if ok then mirrorBuf = ""
		else ioStat.mirrorErr = ioStat.mirrorErr + 1; mirrorDropOldest() end
	end
end

local function fileOut(s)
	fileBuf = fileBuf .. s .. "\n"
	mirrorOut(s)
	if #fileBuf >= 6000 then
		fileFlush(false)
		mirrorFlush()
		lastFlushClock = os.clock()
	end
end

local function forceFlush()
	fileFlush(true)
	mirrorFlush()
	lastFlushClock = os.clock()
end

-- ---------------------------------------------------------------
-- Identitaet: Instanz-Referenz -> ID. Hinweis (Punkt 32/33): IDs sind
-- NUR innerhalb dieses Laufs stabil; Rows halten starke refs, daher
-- bleibt die ID solange stabil, wie die Row existiert.
-- ---------------------------------------------------------------
local ref2id  = setmetatable({}, { __mode = "k" })
local idCount = 0
local function idOf(inst)
	if typeof(inst) ~= "Instance" then return -1 end
	if ref2id[inst] == nil then idCount = idCount + 1; ref2id[inst] = idCount end
	return ref2id[inst]
end

-- ---------------------------------------------------------------
-- norm(): NUR fuer Matching. RAW wird vollstaendig gespeichert.
-- Grenze (Punkt 16 v6-Review): kein volles NFC/NFD in purem Lua.
-- Whitespace-Strip zieht Woerter zusammen (bewusst fuer "Dein
-- Angebot"); Gegenmassnahme: SG-Gruppierung + Wortgrenzen (hasWord).
-- ---------------------------------------------------------------
local UML = {
	["\195\132"] = "ae", ["\195\150"] = "oe", ["\195\156"] = "ue",
	["\195\164"] = "ae", ["\195\182"] = "oe", ["\195\188"] = "ue", ["\195\159"] = "ss",
	["\195\160"] = "a", ["\195\161"] = "a", ["\195\162"] = "a", ["\195\163"] = "a", ["\195\165"] = "a",
	["\195\168"] = "e", ["\195\169"] = "e", ["\195\170"] = "e", ["\195\171"] = "e",
	["\195\172"] = "i", ["\195\173"] = "i", ["\195\174"] = "i", ["\195\175"] = "i",
	["\195\177"] = "n",
	["\195\178"] = "o", ["\195\179"] = "o", ["\195\180"] = "o", ["\195\181"] = "o",
	["\195\185"] = "u", ["\195\186"] = "u", ["\195\187"] = "u",
	["\195\167"] = "c",
	["\194\160"] = "",
	["\226\128\139"] = "", ["\226\128\140"] = "", ["\226\128\141"] = "",
	["\226\128\142"] = "", ["\226\128\143"] = "",
	["\239\187\191"] = "",
	["\226\128\144"] = "-", ["\226\128\145"] = "-", ["\226\128\146"] = "-",
	["\226\128\147"] = "-", ["\226\128\148"] = "-", ["\226\128\149"] = "-",
	["\226\136\146"] = "-",
	["\226\128\153"] = "'", ["\226\128\166"] = "...",
}
local function norm(s)
	if typeof(s) ~= "string" then return "" end
	s = string.lower(s)
	for k, v in pairs(UML) do s = string.gsub(s, k, v) end
	s = string.gsub(s, "%c", "")
	s = string.gsub(s, "%s", "")
	return s
end

local function rawBytes(s)
	if typeof(s) ~= "string" then return "" end
	local non = false
	for i = 1, #s do
		local b = string.byte(s, i)
		if b > 127 or (b < 32 and b ~= 9 and b ~= 10 and b ~= 13) then non = true; break end
	end
	if not non then return "" end
	local out = {}
	for i = 1, math.min(#s, 240) do out[#out + 1] = string.format("%02X", string.byte(s, i)) end
	return "rawBytes[" .. table.concat(out, " ") .. "]"
end

-- Wortgrenzen-Check auf normalisiertem Text (Punkt 24: kein Substring-
-- Fehltreffer von "bestaetigt" in laengerem Wort)
local function hasWord(tn, w)
	local i = 1
	while true do
		local s, e = string.find(tn, w, i, true)
		if not s then return false end
		local before = (s > 1) and string.sub(tn, s - 1, s - 1) or ""
		local after  = string.sub(tn, e + 1, e + 1)
		local badB = (before ~= "" and string.match(before, "%a") ~= nil)
		local badA = (after  ~= "" and string.match(after,  "%a") ~= nil)
		if not badB and not badA then return true end
		i = e + 1
	end
end

-- NEEDLES (normalisiert)
local N_WINDOW  = "deinangebot"
local N_READY   = "bereit"
local N_MYCONF  = "bestaetigen"
local N_OPPCONF = "bestaetigt"
local N_NOTCONF = "nichtbestaetigt"
local N_CANCEL  = "abbrechen"
-- Punkt 23: lockereres Countdown-Pattern (Komma/Punkt-Dezimal, "sekunden"/"sek")
local PAT_COUNTDOWN = "^noch(%d+)[.,]?(%d*)sekunden?"

local function matchRow(tn, nn)
	if string.find(tn, N_NOTCONF, 1, true) then return "NOTCONFIRMED", "Text" end
	if hasWord(tn, N_MYCONF) then return "MY_CONFIRM", "Text" end
	if hasWord(tn, N_OPPCONF) then return "OPP_CONFIRM", "Text" end
	if hasWord(tn, N_WINDOW) then return "WINDOW", "Text" end
	if hasWord(tn, N_READY) then return "READY", "Text" end
	if hasWord(tn, N_CANCEL) then return "CANCEL", "Text" end
	if string.find(tn, PAT_COUNTDOWN) then return "COUNTDOWN", "Text" end
	if string.find(nn, N_WINDOW, 1, true) then return "WINDOW", "Name" end
	if string.find(nn, "trade", 1, true) or string.find(nn, "handel", 1, true) or string.find(nn, "angebot", 1, true) then
		return "NAME_TRADE_HINT", "Name"
	end
	return nil, nil
end

-- ---------------------------------------------------------------
-- Prop-Lesen: pnum/pbool liefert (wert, gelesen). Aufrufer MUESSEN
-- den zweiten Wert auswerten (Punkt 37): Lesefehler duerfen NICHT
-- als false/hidden/disabled interpretiert werden.
-- ---------------------------------------------------------------
local function addPropErr(scan, msg)
	scan.propErrs = scan.propErrs + 1
	if #scan.propErrMsgs < 4 then scan.propErrMsgs[#scan.propErrMsgs + 1] = msg end
end

local function pnum(inst, prop)
	local ok, v = pcall(function() return inst[prop] end)
	if ok and typeof(v) == "number" then return v, true end
	return 0, false
end
local function pbool(inst, prop)
	local ok, v = pcall(function() return inst[prop] end)
	if ok and typeof(v) == "boolean" then return v, true end
	return false, false
end

-- ---------------------------------------------------------------
-- effVisible: Visible-Kette + ScreenGui.Enabled + CanvasGroup.GroupTransparency
-- + Offscreen-Flag. Lesefehler -> unentschieden (true, "unlesbar-..."),
-- NIEMALS als unsichtbar fehldeutet.
-- ---------------------------------------------------------------
local function effVisible(obj)
	local cur = obj
	local depth = 0
	while cur and depth < 60 do
		depth = depth + 1
		local isSG, isCG, isGO = false, false, false
		pcall(function()
			isSG = cur:IsA("ScreenGui")
			isCG = cur:IsA("CanvasGroup")
			isGO = cur:IsA("GuiObject")
		end)
		if isSG then
			local en, ok = pbool(cur, "Enabled")
			if ok and en == false then return false, "gui-disabled(" .. tostring(cur.Name) .. ")" end
		elseif isCG then
			local gt, ok = pnum(cur, "GroupTransparency")
			if ok and gt >= 0.99 then return false, "group-transparency(" .. tostring(cur.Name) .. ")" end
		elseif isGO then
			local vis, ok = pbool(cur, "Visible")
			if ok and vis == false then return false, "hidden(" .. tostring(cur.Name) .. ")" end
		end
		cur = cur.Parent
	end
	local okSg, sg = pcall(function() return obj:FindFirstAncestorOfClass("ScreenGui") end)
	if okSg and sg then
		local okGeo, pos, sgSize = pcall(function() return obj.AbsolutePosition, sg.AbsoluteSize end)
		if okGeo and sgSize.X > 0 then
			local relx = pos.X / sgSize.X
			local rely = pos.Y / sgSize.Y
			if relx < -1.5 or relx > 2.5 or rely < -1.5 or rely > 2.5 then
				return true, "sichtbar+OFFSCREEN-FLAG"
			end
		end
	end
	return true, "sichtbar"
end

local function chainOf(obj)
	local segs = {}
	local cur = obj
	local depth = 0
	while cur and depth < 120 do
		depth = depth + 1
		local nm, cls = "?", "?"
		pcall(function() nm = tostring(cur.Name); cls = cur.ClassName end)
		segs[#segs + 1] = nm .. ":" .. cls
		cur = cur.Parent
	end
	local total = #segs
	while #segs > CFG.MAX_CHAIN do table.remove(segs, 1) end
	if total > #segs then table.insert(segs, 1, "(+" .. (total - #segs) .. " oben)") end
	return table.concat(segs, ">"), total
end

local function geomChainOf(obj)
	local segs = {}
	local cur = obj.Parent
	while cur and #segs < CFG.MAX_GEOM do
		local isFrame = false
		pcall(function()
			isFrame = cur:IsA("Frame") or cur:IsA("ScrollingFrame") or cur:IsA("CanvasGroup")
				or cur:IsA("ImageLabel") or cur:IsA("ImageButton")
		end)
		if isFrame then
			local okG, pos, siz = pcall(function() return cur.AbsolutePosition, cur.AbsoluteSize end)
			if okG then
				segs[#segs + 1] = string.format("%s:%s %dx%d@%d,%d", tostring(cur.Name), cur.ClassName, siz.X, siz.Y, pos.X, pos.Y)
			else
				segs[#segs + 1] = tostring(cur.Name) .. ":" .. cur.ClassName .. " GEOMETRIE-UNLESBAR"
			end
		end
		cur = cur.Parent
	end
	if #segs == 0 then return "-" end
	return table.concat(segs, " > ")
end

local function sgOf(obj)
	local ok, sg = pcall(function() return obj:FindFirstAncestorOfClass("ScreenGui") end)
	if ok then return sg end
	return nil
end

-- ---------------------------------------------------------------
-- Executor-Probe: JEDE Funktion EINMAL gecached getestet (Punkt 15),
-- Ergebnisse in EXEC wiederverwendet.
-- ---------------------------------------------------------------
local EXEC = { hui = nil, hgs = nil, hgsList = nil }

local function execProbe()
	if type(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then
			EXEC.hui = h
			ioStat.gethui = "ok: Instance '" .. h.Name .. "'"
		elseif ok then ioStat.gethui = "ok, aber Typ " .. typeof(h) .. " (nicht Instance)"
		else ioStat.gethui = "FEHLER: " .. tostring(h) end
	else ioStat.gethui = "NICHT vorhanden" end
	if type(gethiddenguis) == "function" then
		local ok, h = pcall(gethiddenguis)
		if ok and typeof(h) == "Instance" then
			EXEC.hgs = h
			ioStat.gethiddenguis = "ok: Instance '" .. h.Name .. "'"
		elseif ok and type(h) == "table" then
			EXEC.hgsList = h
			ioStat.gethiddenguis = "ok: Tabelle (" .. tostring(#h) .. " Eintraege)"
		elseif ok then ioStat.gethiddenguis = "ok, Typ " .. typeof(h)
		else ioStat.gethiddenguis = "FEHLER: " .. tostring(h) end
	else ioStat.gethiddenguis = "NICHT vorhanden" end
	-- unique Probe-Datei (Punkt 16)
	local probeFile = "pc99_io_probe_" .. os.date("%H%M%S") .. ".tmp"
	local okW, eW = pcall(writefile, probeFile, "A")
	if okW then ioStat.wf = "ok" else ioStat.wf = "FEHLER: " .. tostring(eW) end
	if okW and type(readfile) == "function" then
		local okR, c = pcall(readfile, probeFile)
		if okR and c == "A" then
			ioStat.rf = "ok (Inhalt verifiziert)"
			if type(appendfile) == "function" then
				local okA = pcall(appendfile, probeFile, "B")
				local okR2, c2 = pcall(readfile, probeFile)
				if okA and okR2 and c2 == "AB" then ioStat.af = "ok (append verifiziert: AB)"
				else ioStat.af = "FEHLER: append nicht wirksam (" .. tostring(c2) .. ")" end
			else ioStat.af = "NICHT vorhanden" end
		else ioStat.rf = "FEHLER: " .. tostring(c) end
	elseif okW then
		ioStat.rf = "NICHT vorhanden"
	end
	if type(delfile) == "function" then
		local okD, eD = pcall(delfile, probeFile)
		ioStat.delfile = okD and ("ok (" .. probeFile .. " entfernt)") or ("FEHLER: " .. tostring(eD))
	else
		ioStat.delfile = "NICHT vorhanden (" .. probeFile .. " bleibt liegen)"
	end
	if CFG.PROBE_CLIPBOARD then
		if type(setclipboard) == "function" then
			local okC, eC = pcall(setclipboard, "PC99_PROBE")
			ioStat.clip = okC and "ok (Probe)" or ("FEHLER: " .. tostring(eC))
		else ioStat.clip = "NICHT vorhanden" end
	end
	local protName = nil
	if type(syn) == "table" and type(syn.protect_gui) == "function" then protName = "syn.protect_gui" end
	if not protName and type(protectgui) == "function" then protName = "protectgui" end
	if not protName and type(getgenv) == "function" and type(getgenv().protect_gui) == "function" then protName = "getgenv().protect_gui" end
	ioStat.prot = protName or "NICHT vorhanden"
end

local function protectGui(inst)
	if type(syn) == "table" and type(syn.protect_gui) == "function" then pcall(syn.protect_gui, inst)
	elseif type(protectgui) == "function" then pcall(protectgui, inst)
	elseif type(getgenv) == "function" and type(getgenv().protect_gui) == "function" then pcall(getgenv().protect_gui, inst) end
end

-- ---------------------------------------------------------------
-- Container
-- ---------------------------------------------------------------
local contProbe  = {}
local containers = {}
local skipSG     = {}   -- wird je Scan neu aufgebaut (Punkt 11)
local PANEL      = nil  -- forward: Referenz-Ausschluss (Punkt 49)

local function skipNameMatch(name)
	local ln = string.lower(tostring(name))
	for _, pat in ipairs(CFG.SKIP_NAME_PATTERNS) do
		if string.find(ln, pat, 1, true) then return true end
	end
	return false
end

local function addContainer(name, root, src)
	if typeof(root) ~= "Instance" then contProbe[name] = "KEIN Instance"; return end
	for _, c in ipairs(containers) do
		if c.root == root then contProbe[name] = "DOPPELT (=" .. c.name .. ")"; return end
	end
	table.insert(containers, { name = name, root = root, src = src or name })
	contProbe[name] = "ok"
end

local function buildContainers()
	if EXEC.hui then addContainer("gethui", EXEC.hui, "gethui") end
	if EXEC.hgs then addContainer("gethiddenguis", EXEC.hgs, "gethiddenguis") end
	if EXEC.hgsList then
		local n = math.min(#EXEC.hgsList, 10)
		for i = 1, n do addContainer("gethiddenguis[" .. i .. "]", EXEC.hgsList[i], "gethiddenguis") end
		if #EXEC.hgsList > n then contProbe["gethiddenguis"] = tostring(#EXEC.hgsList - n) .. " weitere Eintraege IGNORIERT (Limit 10)" end
	end
	local okCG, cg = pcall(function() return game:GetService("CoreGui") end)
	if okCG and typeof(cg) == "Instance" then addContainer("CoreGui", cg, "CoreGui") end
	local lp = Players.LocalPlayer
	if lp then
		local okPG, pg = pcall(function()
			return lp:FindFirstChild("PlayerGui") or lp:WaitForChild("PlayerGui", 8)
		end)
		if okPG and typeof(pg) == "Instance" then addContainer("PlayerGui", pg, "PlayerGui")
		else contProbe.PlayerGui = "NICHT vorhanden (LocalPlayer ja, PlayerGui fehlt)" end
	else
		contProbe.PlayerGui = "NICHT vorhanden (kein LocalPlayer)"
	end
	-- GUI-Container-Suche; Filter: muss ScreenGui-Descendant haben (Punkt 12)
	local found = 0
	local function scanKids(parent, label)
		if typeof(parent) ~= "Instance" or found >= 8 then return end
		local ok, kids = pcall(function() return parent:GetChildren() end)
		if not ok then return end
		for _, k in ipairs(kids) do
			if found >= 8 then break end
			if typeof(k) == "Instance" then
				local nm = string.lower(tostring(k.Name))
				if string.find(nm, "gui", 1, true) then
					local already = false
					for _, c in ipairs(containers) do if c.root == k then already = true end end
					if not already then
						local hasSG = false
						pcall(function() hasSG = (k:FindFirstChildWhichIsA("ScreenGui", true) ~= nil) end)
						if hasSG then
							addContainer(label .. "/" .. k.Name, k, label)
							found = found + 1
						end
					end
				end
			end
		end
	end
	scanKids(game, "game")
	if okCG and typeof(cg) == "Instance" then scanKids(cg, "CoreGui") end
end

-- ---------------------------------------------------------------
-- Scan EINES Containers
-- objCount-Grenze wird VOR der Verarbeitung geprueft (Punkt 3).
-- st.objects = traversiert (inkl. skipped), st.analyzed = ohne skip.
-- ---------------------------------------------------------------
local TEXTCLASS = { TextLabel = true, TextButton = true, TextBox = true }

local function scanContainer(c, scan)
	local st = { objects = 0, analyzed = 0, textObjs = 0, frames = 0, sgObjs = 0,
	             propErrs = 0, skipped = 0, unreadable = 0 }
	local root = c.root
	local rootIsSG = false
	pcall(function() rootIsSG = root:IsA("ScreenGui") end)
	if rootIsSG and CFG.SKIP_EXEC_GUIS and skipNameMatch(root.Name) then
		st.skipped = st.skipped + 1
		return st
	end
	local ok, descs = pcall(function() return root:GetDescendants() end)
	if not ok then
		scan.contErrs = scan.contErrs + 1
		scan.contErrDetail[c.name] = tostring(descs)
		return st
	end
	-- Skip-ScreenGuis einsammeln (parent-first); eigenes Panel per Referenz
	pcall(function()
		for _, d in ipairs(descs) do
			local isSG = false
			pcall(function() isSG = d:IsA("ScreenGui") end)
			if isSG and CFG.SKIP_EXEC_GUIS and skipNameMatch(d.Name) then
				skipSG[idOf(d)] = true
			end
		end
	end)
	for _, obj in ipairs(descs) do
		scan.objCount = scan.objCount + 1
		if scan.objCount > CFG.MAX_OBJS then
			scan.truncated = true
			break
		end
		st.objects = st.objects + 1
		local par = obj.Parent
		if par and skipSG[idOf(par)] == true then
			st.skipped = st.skipped + 1
			pcall(function()
				if obj:IsA("ScreenGui") then skipSG[idOf(obj)] = true end
			end)
		else
			st.analyzed = st.analyzed + 1
			local clsOk, cls = pcall(function() return obj.ClassName end)
			if not clsOk then
				st.unreadable = st.unreadable + 1
				addPropErr(scan, c.name .. ": ClassName unlesbar an " .. tostring(obj))
			else
				local isSGobj    = (cls == "ScreenGui")
				local isText     = TEXTCLASS[cls] == true
				local isBigFrame = false
				if not isText and not isSGobj then
					pcall(function()
						if obj:IsA("Frame") or obj:IsA("ScrollingFrame") or obj:IsA("CanvasGroup")
							or obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
							local s = obj.AbsoluteSize
							if s.X >= CFG.MIN_FRAME_W and s.Y >= CFG.MIN_FRAME_H then isBigFrame = true end
							if CFG.INVENTORY_ALL_FRAMES and (obj:IsA("Frame") or obj:IsA("ScrollingFrame")) then isBigFrame = true end
						end
					end)
				end
				if isText or isBigFrame or isSGobj then
					local nm = tostring(obj.Name)
					local raw, tok = nil, false
					if isText then
						local okT, v = pcall(function() return obj.Text end)
						if okT and typeof(v) == "string" then raw = v; tok = true
						else
							raw = "UNREADABLE"
							st.propErrs = st.propErrs + 1
							addPropErr(scan, c.name .. "/" .. nm .. ": Text unlesbar")
						end
					end
					local okPS, pos, siz = pcall(function() return obj.AbsolutePosition, obj.AbsoluteSize end)
					if not okPS then
						pos = Vector2.new(0, 0); siz = Vector2.new(0, 0)
						st.propErrs = st.propErrs + 1
						addPropErr(scan, c.name .. "/" .. nm .. ": Geometrie unlesbar")
					end
					local z = 0
					if not isSGobj then
						local zok
						z, zok = pnum(obj, "ZIndex")
						if not zok then st.propErrs = st.propErrs + 1 end
					end
					local vis, visOk = true, true
					if isSGobj then
						vis, visOk = pbool(obj, "Enabled")
						if not visOk then st.propErrs = st.propErrs + 1 end
					else
						vis, visOk = pbool(obj, "Visible")
						if not visOk then st.propErrs = st.propErrs + 1 end
					end
					local ev, why
					if isText then
						ev, why = effVisible(obj) -- volle Kette nur bei Textobjekten (Hot Path)
					elseif isSGobj then
						ev, why = vis, "sg(vis=Enabled)"
					else
						ev, why = vis, "frame(vis-only)"
					end
					local path, pathTotal = chainOf(obj)
					local sg = sgOf(obj)
					local sgid, sgName, sgEn, sgDisp = 0, "-", nil, nil
					local sgX, sgY, sgW, sgH = 0, 0, 0, 0
					if sg then
						sgid = idOf(sg); sgName = tostring(sg.Name)
						sgEn, _ = pbool(sg, "Enabled")
						sgDisp, _ = pnum(sg, "DisplayOrder")
						local okSG = false
						okSG, sgX, sgY, sgW, sgH = pcall(function()
							local p = sg.AbsolutePosition; local s = sg.AbsoluteSize
							return p.X, p.Y, s.X, s.Y
						end)
						if not okSG then
							sgX, sgY, sgW, sgH = 0, 0, 0, 0
							st.propErrs = st.propErrs + 1
							addPropErr(scan, c.name .. "/" .. nm .. ": SG-Geometrie unlesbar")
						end
					end
					local gchain = geomChainOf(obj)
					local tn = tok and norm(raw) or ""
					local nn = norm(nm)
					local needle, via
					if tok then needle, via = matchRow(tn, nn) end
					local relx = sgW > 0 and (pos.X - sgX) / sgW or 0
					local rely = sgH > 0 and (pos.Y - sgY) / sgH or 0
					table.insert(scan.rows, {
						ref = obj, id = idOf(obj), name = nm, cls = cls,
						raw = raw, tn = tn, rb = (tok and rawBytes(raw) or ""),
						posX = pos.X, posY = pos.Y, w = siz.X, h = siz.Y,
						z = z, vis = vis, visOk = visOk, eff = ev, why = why,
						path = path, pathTotal = pathTotal,
						sg = sg,              -- FIX Punkt 2/25/56: Root-Referenz JE Row
						sgid = sgid, sgName = sgName, sgEn = sgEn, sgDisp = sgDisp,
						sgX = sgX, sgY = sgY, sgW = sgW, sgH = sgH,
						relx = relx, rely = rely, btnRegion = (relx >= 0.6 and rely >= 0.7),
						geom = gchain, needle = needle, via = via,
						frame = (isBigFrame and not isText), isSG = isSGobj,
					})
					if isText then st.textObjs = st.textObjs + 1
					elseif isSGobj then st.sgObjs = st.sgObjs + 1
					else st.frames = st.frames + 1 end
					if needle then table.insert(scan.hits, scan.rows[#scan.rows]) end
				end
			end
		end
	end
	return st
end

local function fullScan(tag)
	skipSG = {} -- je Scan neu (Punkt 11)
	if PANEL and typeof(PANEL) == "Instance" then skipSG[idOf(PANEL)] = true end
	local scan = {
		rows = {}, hits = {}, t = nowStr(), tag = tag or "SCAN",
		truncated = false, contErrs = 0, propErrs = 0, objCount = 0,
		contErrDetail = {}, propErrMsgs = {}, perCont = {}, valid = false, durMs = 0,
	}
	local clock0 = os.clock()
	for _, c in ipairs(containers) do
		scan.perCont[c.name] = scanContainer(c, scan)
	end
	local seen, uniq = {}, {}
	for _, r in ipairs(scan.rows) do
		if seen[r.id] == nil then seen[r.id] = true; table.insert(uniq, r) end
	end
	scan.rows = uniq
	scan.hits = {}
	for _, r in ipairs(scan.rows) do
		if r.needle then table.insert(scan.hits, r) end
	end
	scan.durMs = math.floor((os.clock() - clock0) * 1000)
	scan.valid = (not scan.truncated) and (scan.contErrs == 0) and (scan.propErrs == 0)
	return scan
end

-- ---------------------------------------------------------------
-- Row -> Zeilen (je Row vollstaendig; Ausgabemengen via CFG begrenzt)
-- ---------------------------------------------------------------
local function rowLines(r, p)
	local L = {}
	p = p or "  "
	L[#L + 1] = string.format("%s%s %s id=%d", p, r.cls, r.path, r.id)
	if r.raw ~= nil then
		L[#L + 1] = string.format("%s   Text(%d): %s", p, #r.raw, r.raw)
		if #r.rb > 0 then L[#L + 1] = string.format("%s   %s", p, r.rb) end
		L[#L + 1] = string.format("%s   norm: %s", p, r.tn)
	end
	L[#L + 1] = string.format("%s   pos=%d,%d size=%dx%d z=%s vis=%s(ok=%s) eff=%s(%s) rel=%.2f/%.2f btnRegion=%s",
		p, r.posX, r.posY, r.w, r.h, tostring(r.z), tostring(r.vis), tostring(r.visOk),
		tostring(r.eff), tostring(r.why), r.relx, r.rely, tostring(r.btnRegion))
	L[#L + 1] = string.format("%s   SG='%s' id=%d Enabled=%s DisplayOrder=%s", p, r.sgName, r.sgid,
		tostring(r.sgEn), tostring(r.sgDisp))
	L[#L + 1] = string.format("%s   geomChain: %s", p, r.geom)
	if r.needle then L[#L + 1] = string.format("%s   MATCH: %s via %s", p, r.needle, r.via) end
	return L
end

-- ---------------------------------------------------------------
-- Diff (Key = Instanz-ID; nur gueltige Scans werden Basis)
-- ---------------------------------------------------------------
local function parentPathOf(path)
	local m = string.match(path or "", "^(.*)>[^>]*$")
	return m or ""
end

local function classifyDiff(prevRows, curRows)
	local prevById = {}
	for _, r in ipairs(prevRows) do prevById[r.id] = r end
	local curById = {}
	local NEW, CHANGED, REMOVED = {}, {}, {}
	for _, r in ipairs(curRows) do
		curById[r.id] = r
		local p = prevById[r.id]
		if not p then
			table.insert(NEW, r)
		else
			local f = {}
			if p.raw ~= r.raw then
				table.insert(f, "text: [" .. tostring(p.raw) .. "] -> [" .. tostring(r.raw) .. "]")
			end
			if p.posX ~= r.posX or p.posY ~= r.posY then
				table.insert(f, string.format("pos: %d,%d -> %d,%d", p.posX, p.posY, r.posX, r.posY))
			end
			if p.w ~= r.w or p.h ~= r.h then
				table.insert(f, string.format("size: %dx%d -> %dx%d", p.w, p.h, r.w, r.h))
			end
			if p.vis ~= r.vis then table.insert(f, "visible: " .. tostring(p.vis) .. " -> " .. tostring(r.vis)) end
			if p.eff ~= r.eff then table.insert(f, "effVisible: " .. tostring(p.eff) .. " -> " .. tostring(r.eff)) end
			if p.z ~= r.z then table.insert(f, "zindex: " .. tostring(p.z) .. " -> " .. tostring(r.z)) end
			if p.sgEn ~= r.sgEn then table.insert(f, "SG.Enabled: " .. tostring(p.sgEn) .. " -> " .. tostring(r.sgEn)) end
			if p.sgid ~= r.sgid then
				table.insert(f, "SG-Wechsel: " .. tostring(p.sgName) .. " -> " .. tostring(r.sgName))
			end
			if parentPathOf(p.path) ~= parentPathOf(r.path) then
				table.insert(f, "parent: " .. tostring(parentPathOf(p.path)) .. " -> " .. tostring(parentPathOf(r.path)))
			end
			if #f > 0 then
				local jitter = true
				for _, fld in ipairs(f) do
					if string.sub(fld, 1, 5) ~= "pos: " and string.sub(fld, 1, 6) ~= "size: " then jitter = false; break end
				end
				table.insert(CHANGED, { row = r, fields = f, jitter = jitter })
			end
		end
	end
	for _, p in ipairs(prevRows) do
		if not curById[p.id] then table.insert(REMOVED, p) end
	end
	return NEW, CHANGED, REMOVED
end

-- ---------------------------------------------------------------
-- State-Maschine: Merkmale muessen in EINER ScreenGui leben;
-- tradeRootRef = DIESE ScreenGui-Instanz (jetzt mit echtem sg-Field).
-- Root-Auswahl deterministisch: vorheriger Root bevorzugt, sonst
-- kleinste sgid; Mehrfach-Kandidaten werden geloggt (Punkt 26/27).
-- ---------------------------------------------------------------
local tradeRootRef, tradeRootId, tradeRootPath = nil, 0, "-"
local history = {}
local rootWarned = false

local function setState(s, detail)
	local last = history[#history]
	if last and last.state == s then
		last.n = last.n + 1
		return
	end
	history[#history + 1] = { state = s, t = nowStr(), n = 1, detail = detail or "" }
	fileOut(string.format("[%s] STATE: %s  (%s)", nowStr(), s, detail or ""))
	forceFlush() -- Punkt 43: States sofort an Datei
	print("[PC99] STATE: " .. s .. "  " .. (detail or ""))
end

local function inKnownHierarchy(ref)
	-- Punkt 28: Root muss bis zu einem bekannten Container laufen.
	-- Robust gegen waehrend des Laufs zerstoerte/entfernte Roots:
	-- typeof-Gate vorab, jeder Parent-Zugriff pcall-gesichert, Depth-Cap.
	if typeof(ref) ~= "Instance" then return false end
	local cur = ref
	local depth = 0
	while cur and depth < 120 do
		depth = depth + 1
		for _, c in ipairs(containers) do
			if c.root == cur then return true end
		end
		local ok, p = pcall(function() return cur.Parent end)
		if not ok then return false end
		cur = p
	end
	return false
end

local function rootAlive()
	if tradeRootRef == nil then return false, "kein-Root" end
	local okP, parent = pcall(function() return tradeRootRef.Parent end)
	if not okP then return false, "parent-unlesbar" end
	if parent == nil then return false, "parent-nil (zerstoert)" end
	if not inKnownHierarchy(tradeRootRef) then return false, "nicht-mehr-in-bekannter-Hierarchie" end
	-- effVisible prueft ScreenGui.Enabled selbst; zweiter Rueckgabe genutzt (Punkt 1)
	return effVisible(tradeRootRef)
end

local function groupBySG(hits)
	local g = {}
	for _, r in ipairs(hits) do
		if r.sgid and r.sgid > 0 and r.needle ~= "NAME_TRADE_HINT" then
			local grp = g[r.sgid]
			if not grp then
				grp = { sgid = r.sgid, sgName = r.sgName, sgRef = r.sg, rows = {},
					win = false, winViaText = false, ready = false, readyIsBtn = false, readyBtnRegion = nil,
					myconf = false, oppconf = false, notconf = false, cancel = false, countdown = nil }
				g[r.sgid] = grp
			end
			table.insert(grp.rows, r)
			local n = r.needle
			if n == "WINDOW" then grp.win = true; if r.via == "Text" then grp.winViaText = true end end
			if n == "READY" then
				grp.ready = true
				if r.cls == "TextButton" then
					grp.readyIsBtn = true
					grp.readyBtnRegion = r.btnRegion
				end
			end
			if n == "MY_CONFIRM" then grp.myconf = true end
			if n == "OPP_CONFIRM" then grp.oppconf = true end
			if n == "NOTCONFIRMED" then grp.notconf = true end
			if n == "CANCEL" then grp.cancel = true end
			if n == "COUNTDOWN" then grp.countdown = r.raw end
		end
	end
	return g
end

local function detectState(scan)
	local g = groupBySG(scan.hits)
	local cands = {}
	for _, grp in pairs(g) do
		if grp.win and grp.winViaText then table.insert(cands, grp) end
	end
	table.sort(cands, function(a, b) return a.sgid < b.sgid end) -- deterministisch (Punkt 27)
	local cand = nil
	if tradeRootId ~= 0 then
		for _, grp in ipairs(cands) do
			if grp.sgid == tradeRootId then cand = grp; break end -- vorheriger Root bevorzugt (Punkt 26)
		end
	end
	if not cand and #cands > 0 then
		cand = cands[1]
		if #cands > 1 then
			local names = {}
			for _, grp in ipairs(cands) do names[#names + 1] = grp.sgName .. "(id=" .. grp.sgid .. ")" end
			fileOut(string.format("[%s] INFO: %d WINDOW-ScreenGuis gleichzeitig — Root-Wechsel auf kleinste id (alle: %s)",
				nowStr(), #cands, table.concat(names, ", ")))
		end
	end
	if cand then
		if cand.sgid ~= tradeRootId then rootWarned = false end -- nur bei Root-Wechsel (Punkt 47)
		tradeRootRef, tradeRootId = cand.sgRef, cand.sgid        -- sgRef ist jetzt ECHT (row.sg)
		tradeRootPath = "SG '" .. cand.sgName .. "'"
		local m = {}
		if cand.ready then m[#m + 1] = "READY(" .. (cand.readyIsBtn and ("Button,btnRegion=" .. tostring(cand.readyBtnRegion)) or "nur-Label") .. ")" end
		if cand.myconf then m[#m + 1] = "MY_CONFIRM" end
		if cand.oppconf then m[#m + 1] = "OPP_CONFIRM" end
		if cand.notconf then m[#m + 1] = "NOT_CONFIRMED" end
		if cand.cancel then m[#m + 1] = "CANCEL" end
		if cand.countdown then m[#m + 1] = "COUNTDOWN[" .. cand.countdown .. "]" end
		local detail = "SG='" .. cand.sgName .. "' (id=" .. cand.sgid .. ") Merkmale: " ..
			(table.concat(m, ",") ~= "" and table.concat(m, ",") or "keine")
		if cand.countdown then setState("COUNTDOWN", detail)
		elseif cand.notconf then setState("NOT_CONFIRMED", detail)
		elseif cand.myconf then setState("CONFIRM_STAGE", detail)
		elseif cand.ready then setState("READY", detail)
		elseif #m > 0 then setState("OPEN", detail)
		else
			fileOut(string.format("[%s] INFO: WINDOW-Needle allein in SG id=%d ohne weitere Merkmale — kein State",
				nowStr(), cand.sgid))
		end
		return
	end
	if tradeRootRef then
		local alive, why = rootAlive()
		if not alive then
			setState("CLOSED", "tradeRoot id=" .. tradeRootId .. " (" .. tradeRootPath .. ") weg: " .. tostring(why) ..
				" — REMOVED-Diffs allein waeren KEIN CLOSED")
			tradeRootRef, tradeRootId = nil, 0
		elseif not rootWarned then
			rootWarned = true
			fileOut(string.format("[%s] INFO: WINDOW-Needle fehlt, aber Root id=%d lebt (%s) -> KEIN CLOSED",
				nowStr(), tradeRootId, tostring(why)))
		end
	end
end

-- ---------------------------------------------------------------
-- Events: Root/SG-Signale (mit MAX_ROOT_CONNS begrenzt, Punkt 55)
-- + Text/Visible-Watcher. Position/Size absichtlich ohne Event
-- (Layout-Flut) -> Abdeckung ueber 2s-Diff + Probe-Scans.
-- ---------------------------------------------------------------
local boundSG = {}
local probeFlag = false
local lastProbeScan = 0

local function bindSignals(inst)
	if rootConnCount >= CFG.MAX_ROOT_CONNS then
		if not rootConnWarned then
			rootConnWarned = true
			fileOut("WARNUNG: MAX_ROOT_CONNS erreicht — weitere Root/SG-Signale NICHT gebunden (Diff-Intervall deckt ab)")
		end
		return
	end
	pcall(function()
		rootConnCount = rootConnCount + 3
		table.insert(rootCons, inst.DescendantAdded:Connect(function() probeFlag = true end))
		table.insert(rootCons, inst.DescendantRemoving:Connect(function() probeFlag = true end))
		table.insert(rootCons, inst.AncestryChanged:Connect(function() probeFlag = true end))
	end)
end

local boundRoots = {}
local function bindRoots()
	for _, c in ipairs(containers) do
		local rid = idOf(c.root)
		if rid >= 0 and not boundRoots[rid] then
			boundRoots[rid] = true
			bindSignals(c.root)
		end
	end
end

local function rebindWatchers(scan)
	-- boundSG aufraeumen (Punkt 10): nicht mehr vorhandene SGs raus
	local aliveSG = {}
	for _, r in ipairs(scan.rows) do
		if r.isSG then aliveSG[r.sgid] = true end
	end
	for id in pairs(boundSG) do
		if not aliveSG[id] then boundSG[id] = nil end
	end
	for _, r in ipairs(scan.rows) do
		if r.isSG and not boundSG[r.sgid] then
			boundSG[r.sgid] = true
			if r.ref then bindSignals(r.ref) end
		end
	end
	-- Text-Watcher: tote loesen, neue binden (Limit = Verbindungen, Punkt 9)
	local alive = {}
	for _, r in ipairs(scan.rows) do alive[r.id] = true end
	for i = #watchCons, 1, -1 do
		local w = watchCons[i]
		if not alive[w.id] then
			pcall(function() w.con:Disconnect() end)
			table.remove(watchCons, i)
		end
	end
	local watchIds = {}
	for _, w in ipairs(watchCons) do watchIds[w.id] = true end
	local count = #watchCons
	for _, r in ipairs(scan.rows) do
		if count >= CFG.MAX_WATCHERS then break end
		if TEXTCLASS[r.cls] and not watchIds[r.id] then
			local ok = pcall(function()
				local c1 = r.ref:GetPropertyChangedSignal("Text"):Connect(function() probeFlag = true end)
				table.insert(watchCons, { id = r.id, con = c1 })
				local c2 = r.ref:GetPropertyChangedSignal("Visible"):Connect(function() probeFlag = true end)
				table.insert(watchCons, { id = r.id, con = c2 })
			end)
			if ok then count = count + 2 end
		end
	end
end

-- ---------------------------------------------------------------
-- Diagnose-Panel (Referenz + Praefix-Ausschluss; ersetzt NUR das
-- eigene Alt-Panel der bereits gestoppten Instanz)
-- ---------------------------------------------------------------
local altPanelRemoved = false
local host = nil
pcall(function() if EXEC.hui then host = EXEC.hui end end)
if typeof(host) ~= "Instance" then
	local lp = Players.LocalPlayer
	if lp then pcall(function() host = lp:FindFirstChild("PlayerGui") or lp:WaitForChild("PlayerGui", 5) end) end
end
if typeof(host) == "Instance" then
	pcall(function()
		local old = host:FindFirstChild("PC99DeepScan7")
		if old then old:Destroy(); altPanelRemoved = true end -- eigenes Alt-Panel (gestoppte Instanz)
	end)
	pcall(function()
		PANEL = Instance.new("ScreenGui")
		PANEL.Name = "PC99DeepScan7"
		PANEL.ResetOnSpawn = false
		PANEL.DisplayOrder = 999999
		protectGui(PANEL)
		PANEL.Parent = host
		local box = Instance.new("Frame")
		box.Name = "Box"
		box.Size = UDim2.new(0, 360, 0, 92)
		box.Position = UDim2.new(0, 8, 0, 8)
		box.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
		box.BackgroundTransparency = 0.15
		box.BorderSizePixel = 0
		box.Parent = PANEL
		local txt = Instance.new("TextLabel")
		txt.Name = "Txt"
		txt.Size = UDim2.new(1, -12, 1, -10)
		txt.Position = UDim2.new(0, 6, 0, 5)
		txt.BackgroundTransparency = 1
		txt.TextXAlignment = Enum.TextXAlignment.Left
		txt.TextYAlignment = Enum.TextYAlignment.Top
		txt.TextWrapped = true
		txt.TextSize = 13
		txt.TextColor3 = Color3.fromRGB(90, 255, 120)
		txt.Font = Enum.Font.Code
		txt.Text = "PC99 v7: starte..."
		txt.Parent = box
	end)
end

-- ---------------------------------------------------------------
-- Report-Bausteine
-- ---------------------------------------------------------------
local scanNo = 0
local totals = { new = 0, changed = 0, removed = 0, jitter = 0, scans = 0, validScans = 0, partial = 0, truncated = 0 }
local diffSects = 0
local prevRows = nil
local baselineReady, baselineStable = false, false
local lastScanInfo = "noch kein Scan"
local lastScan = nil

local function headerOut()
	fileOut("PC99 DEEP-SCAN v7 | Start " .. nowStr())
	fileOut("READ-ONLY-Bedeutung: keine Klicks, kein Handel, keine Spiel-Interaktion. Geschrieben werden NUR eigene Report-Dateien + eigenes Diagnose-Panel.")
	fileOut("Panel-Hinweis: " .. (altPanelRemoved and "eigenes Alt-Panel 'PC99DeepScan7' wurde ersetzt (dokumentierter Seiteneffekt, gestoppte Instanz)" or "kein Alt-Panel musste entfernt werden"))
	fileOut("ID-Grenze: Instanz-IDs sind nur innerhalb dieses Laufs stabil (Pfad + Klasse in jeder Row erlauben Vergleich ueber Laeufe).")
	fileOut("Unicode-Grenze: norm = Latin-1-Diakritika + NBSP/ZeroWidth/Dashes; kein volles NFC/NFD. RAW + rawBytes je Text in der Datei.")
	fileOut("")
	fileOut("EXECUTOR-PROBE (einzeln, gecached):")
	fileOut("  gethui          : " .. ioStat.gethui)
	fileOut("  gethiddenguis   : " .. ioStat.gethiddenguis)
	fileOut("  writefile       : " .. ioStat.wf)
	fileOut("  readfile        : " .. ioStat.rf)
	fileOut("  appendfile      : " .. ioStat.af)
	fileOut("  delfile         : " .. ioStat.delfile)
	fileOut("  setclipboard    : " .. ioStat.clip)
	fileOut("  protect_gui     : " .. ioStat.prot)
	fileOut("")
	fileOut("CONTAINER-PROBE:")
	for name, st in pairs(contProbe) do fileOut("  " .. name .. " : " .. st) end
	fileOut("")
	fileOut(string.format("CFG: RUNTIME=%ds MAX_OBJS=%d(traversiert) MAX_WATCHERS=%d(Verbindungen) MAX_ROOT_CONNS=%d MIN_FRAME=%dx%d ALL_FRAMES=%s MAX_SECT=%d MAX_DIFFS=%d(+Kompaktmodus) BASELINE=%dx%d%s",
		CFG.RUNTIME, CFG.MAX_OBJS, CFG.MAX_WATCHERS, CFG.MAX_ROOT_CONNS, CFG.MIN_FRAME_W, CFG.MIN_FRAME_H,
		tostring(CFG.INVENTORY_ALL_FRAMES), CFG.MAX_SECT_CHARS, CFG.MAX_DIFFS_FILE,
		CFG.BASELINE_MIN_MATCH, CFG.BASELINE_PASSES,
		CFG.REQUIRE_STABLE_BASELINE and " REQUIRED" or ""))
	fileOut("")
end

local function scanStatsLine(scan)
	local parts = {}
	for name, st in pairs(scan.perCont or {}) do
		parts[#parts + 1] = string.format("%s[trav=%d anz=%d txt=%d frm=%d sg=%d pErr=%d skip=%d]", name,
			st.objects, st.analyzed, st.textObjs, st.frames, st.sgObjs, st.propErrs, st.skipped)
	end
	return table.concat(parts, " ")
end

local function invalidLine(scan)
	fileOut(string.format("[%s] Scan#%d (%s) UNGUELTIG: truncated=%s contErrs=%d propErrs=%d — KEIN Diff, KEIN State, prev bleibt",
		nowStr(), scanNo, scan.tag, tostring(scan.truncated), scan.contErrs, scan.propErrs))
	if scan.contErrs > 0 then
		for name, msg in pairs(scan.contErrDetail) do
			fileOut("   Container-FEHLER " .. name .. ": " .. msg)
		end
	end
	for _, msg in ipairs(scan.propErrMsgs) do fileOut("   Prop-FEHLER: " .. msg) end
	fileOut("   " .. scanStatsLine(scan))
	forceFlush()
end

local function writeDiffSection(scan, NEW, CHANGED, REMOVED)
	local counts = string.format("NEW=%d CHANGED=%d REMOVED=%d", #NEW, #CHANGED, #REMOVED)
	diffSects = diffSects + 1
	if diffSects > CFG.MAX_DIFFS_FILE then
		-- Kompaktmodus (Punkt 42): 1 Zeile je Diff, erste Pfade dabei
		local first = ""
		if #NEW > 0 then first = " ersterNEW: " .. NEW[1].path
		elseif #CHANGED > 0 then first = " ersterCH: " .. CHANGED[1].row.path
		elseif #REMOVED > 0 then first = " ersterREM: " .. REMOVED[1].path end
		fileOut(string.format("[%s] DIFF#%d KOMPAKT (%s): %s%s", scan.t, diffSects, scan.tag, counts, first))
		return
	end
	local L = {}
	local basis = baselineStable and "Basis:Baseline(STABIL)" or "Basis:letzte-gueltiger-Scan(UNSTABILE- Baseline!)"
	L[#L + 1] = string.format("=== DIFF #%d [%s] Scan#%d (%s) dur=%dms %s ===", diffSects, scan.t, scanNo, scan.tag, scan.durMs, basis)
	L[#L + 1] = "  Diese-Scan-Statistik: " .. scanStatsLine(scan)
	L[#L + 1] = string.format("  %s | propErrs dieser Scan=%d (Zahlen immer vollstaendig; Listings bis Groessen-Grenzen)", counts, scan.propErrs)
	local chars = #L[1] + #L[2] + #L[3]
	local cap = false
	local function budget(lines)
		for _, ln in ipairs(lines) do
			if chars + #ln + 1 > CFG.MAX_SECT_CHARS then return false end
			chars = chars + #ln + 1
			L[#L + 1] = ln
		end
		return true
	end
	if #NEW > 0 then
		L[#L + 1] = "  -- NEW --"
		for _, r in ipairs(NEW) do
			if not budget(rowLines(r, "   ")) then cap = true; break end
		end
	end
	if not cap then
		-- Jitter trennen: reine pos/size-Aenderungen (Lobby-Animationen) als
		-- Zaehler, strukturelle CHANGED (Text/Sichtbarkeit/z/SG/Parent) als Listing
		local chStruct, jitterN = {}, 0
		for _, ch in ipairs(CHANGED) do
			if CFG.DIFF_JITTER_SUPPRESS and ch.jitter then jitterN = jitterN + 1
			else table.insert(chStruct, ch) end
		end
		totals.jitter = totals.jitter + jitterN
		if jitterN > 0 then
			L[#L + 1] = string.format("  POSITIONEN-JITTER (nur pos/size, Animationen): %d unterdrueckt (CFG.DIFF_JITTER_SUPPRESS)", jitterN)
			chars = chars + #L[#L + 1] + 1
		end
		if #chStruct > 0 then
			L[#L + 1] = "  -- CHANGED (strukturell) --"
			chars = chars + #L[#L + 1] + 1
			for _, ch in ipairs(chStruct) do
				local ls = {}
				ls[#ls + 1] = string.format("   %s id=%d", ch.row.path, ch.row.id)
				for _, f in ipairs(ch.fields) do ls[#ls + 1] = "     " .. f end
				if not budget(ls) then cap = true; break end
			end
		end
	end
	if not cap and #REMOVED > 0 then
		L[#L + 1] = "  -- REMOVED (rein inventarisch; CLOSED NUR aus Root-Pruefung) --"
		for _, r in ipairs(REMOVED) do
			local ls = {}
			ls[#ls + 1] = string.format("   %s %s id=%d", r.cls, r.path, r.id)
			if r.raw then ls[#ls + 1] = "     Text: " .. r.raw end
			if not budget(ls) then cap = true; break end
		end
	end
	if cap then
		L[#L + 1] = string.format("  ...SEKTION TRUNCATED bei MAX_SECT_CHARS=%d (Gezaehltes bleibt vollstaendig)", CFG.MAX_SECT_CHARS)
	end
	fileOut(table.concat(L, "\n"))
	forceFlush() -- Punkt 43: Diff-Sektionen sofort an Datei
end

local function runBaseline()
	local stableCount = 0
	local lastValid = nil
	local baselineClock = os.clock()
	for p = 1, CFG.BASELINE_PASSES do
		-- Gesamt-Zeitbudget: Lobby-UI animiert permanent; ohne Limit laeuft
		-- die Baseline sonst minutenlang und das Panel bleibt auf "starte..."
		if os.clock() - baselineClock > CFG.BASELINE_MAX_WALL and lastValid ~= nil then
			fileOut(string.format("[%s] BASELINE-Zeitlimit (%ds) — akzeptiere letzten gueltigen Pass.", nowStr(), CFG.BASELINE_MAX_WALL))
			break
		end
		print("[PC99] Baseline " .. p .. "/" .. CFG.BASELINE_PASSES .. " ...")
		local scan = fullScan("BASELINE" .. p)
		totals.scans = totals.scans + 1
		lastScan = scan -- Punkt 7: letzter Scan IST der letzte Scan
		if not scan.valid then
			fileOut(string.format("[%s] Baseline-Pass %d UNGUELTIG (truncated=%s contErrs=%d propErrs=%d) — zaehlt NICHT fuer Stabilitaet",
				nowStr(), p, tostring(scan.truncated), scan.contErrs, scan.propErrs))
		elseif lastValid == nil then
			lastValid = scan
			stableCount = 1
		else
			local n, c, r = classifyDiff(lastValid.rows, scan.rows)
			local jitterN = 0
			for _, ch in ipairs(c) do if ch.jitter then jitterN = jitterN + 1 end end
			local structural = #n + #r + (#c - jitterN)
			if structural == 0 then
				stableCount = stableCount + 1
				if jitterN > 0 then
					fileOut(string.format("[%s] Baseline-Pass %d: STRUKTURELL identisch zu Pass %d (stable %d/%d, %d Positions-Jitter von Animationen toleriert)",
						nowStr(), p, p - 1, stableCount, CFG.BASELINE_MIN_MATCH, jitterN))
				else
					fileOut(string.format("[%s] Baseline-Pass %d: IDENTISCH zu Pass %d (stable %d/%d)",
						nowStr(), p, p - 1, stableCount, CFG.BASELINE_MIN_MATCH))
				end
				lastValid = scan
				if stableCount >= CFG.BASELINE_MIN_MATCH then break end
			else
				stableCount = 1
				lastValid = scan
				fileOut(string.format("[%s] Baseline-Pass %d: %d STRUKTURELLE Aenderungen vs Vor-Pass — Stabilitaet reset (NEW=%d CH=%d(Jitter %d) REM=%d)",
					nowStr(), p, structural, #n, #c, jitterN, #r))
			end
		end
		if PANEL then
			pcall(function()
				PANEL.Box.Txt.Text = string.format("PC99 v7 | Baseline %d/%d  rows=%d  %dms\nstabil %d/%d | gesamt %.0fs — bitte warten",
					p, CFG.BASELINE_PASSES, #scan.rows, scan.durMs, stableCount, CFG.BASELINE_MIN_MATCH, os.clock() - baselineClock)
			end)
		end
		task.wait(CFG.BASELINE_WAIT)
	end
	if lastValid == nil then
		fileOut("!! BASELINE FEHLGESCHLAGEN: kein gueltiger Scan in " .. CFG.BASELINE_PASSES .. " Passes — KEINE Diffs.")
		return false
	end
	prevRows = lastValid.rows
	baselineReady = true
	baselineStable = (stableCount >= CFG.BASELINE_MIN_MATCH)
	if not baselineStable and CFG.REQUIRE_STABLE_BASELINE then
		baselineReady = false
		fileOut("!! Baseline NIE stabil und REQUIRE_STABLE_BASELINE=true -> Diffs deaktiviert (CFG anpassen fuer erzwungenen Modus).")
		return false
	end
	fileOut("")
	fileOut(string.format("== BASELINE %s: %d Rows [%s] ==",
		baselineStable and "STABIL akzeptiert" or "UNSTABIL erzwungen (jede DIFF-Sektion kennzeichnet die Basis)",
		#lastValid.rows, lastValid.t))
	if not baselineStable then
		fileOut("!! WARNUNG: Baseline war in " .. CFG.BASELINE_PASSES .. " Passes nie stabil — Diffs koennen Fehlalarme enthalten (in jeder Sektion markiert).")
	end
	fileOut("")
	forceFlush()
	return true
end

local function dumpBaseline(rows)
	fileOut(string.format("== BASELINE-DUMP: %d Rows im Speicher; hier: saemtliche Treffer + Rest bis %d (Ausgabemengen-Grenze; jede ausgegebene Row ist vollstaendig) ==",
		#rows, CFG.MAX_BASE_DUMP))
	local shown = 0
	for _, r in ipairs(rows) do
		if shown >= CFG.MAX_BASE_DUMP then break end
		if r.needle then
			for _, ln in ipairs(rowLines(r, "  ")) do fileOut(ln) end
			shown = shown + 1
		end
	end
	for _, r in ipairs(rows) do
		if shown >= CFG.MAX_BASE_DUMP then break end
		if not r.needle then
			for _, ln in ipairs(rowLines(r, "  ")) do fileOut(ln) end
			shown = shown + 1
		end
	end
	if shown < #rows then
		fileOut(string.format("  ... +%d Rows nur im Speicher", #rows - shown))
	end
	fileOut("")
end

local function summary()
	fileOut("")
	fileOut("== ABSCHLUSS-REPORT " .. nowStr() .. " ==")
	fileOut(string.format("Laufzeit: %.1fs (Limit %ds) | Scans total=%d valid=%d partial=%d truncated=%d | Datei: %s",
		os.clock() - startClock, CFG.RUNTIME, totals.scans, totals.validScans, totals.partial, totals.truncated, filePath))
	fileOut(string.format("Diffs: NEW=%d CHANGED=%d REMOVED=%d jitterOnly=%d | Sektionen: %d (danach Kompaktmodus) | IO: writes=%d appends=%d wfErr=%d appendErr=%d dropped=%dB mirrorErr=%d mirrorDropped=%dB %s",
		totals.new, totals.changed, totals.removed, totals.jitter, diffSects,
		ioStat.writes, ioStat.appends, ioStat.wfErr, ioStat.appendErr, ioStat.dropped,
		ioStat.mirrorErr, mirrorDropped,
		ioStat.appendErrMsg ~= "" and ("(" .. ioStat.appendErrMsg .. ")") or ""))
	for _, h in ipairs(history) do
		fileOut(string.format("  STATE-HIST [%s] %s (n=%d) %s", h.t, h.state, h.n, h.detail))
	end
	if tradeRootRef then
		fileOut("Offen am Ende: tradeRoot id=" .. tradeRootId .. " (" .. tradeRootPath .. ") lebt noch")
	end
	fileOut("Baseline: " .. (baselineReady and (baselineStable and "STABIL" or "UNSTABIL(erzwungen)") or (CFG.REQUIRE_STABLE_BASELINE and "NICHT akzeptiert" or "FEHLGESCHLAGEN")))
	fileOut("Letzter Scan: " .. lastScanInfo)
	fileOut("Container (letzter Scan, inkl. ungueltig): " .. scanStatsLine(lastScan or { perCont = {} }))
	fileOut("Verbindungen am Ende: rootConns~" .. rootConnCount .. " watcher=" .. #watchCons)
	forceFlush()
	stopAll() -- Punkt 5: Disconnects NACH dem Schreiben
end

-- ---------------------------------------------------------------
-- Hauptloop (xpcall: auch bei Fehler wird Summary geschrieben, Punkt 44)
-- ---------------------------------------------------------------
local function mainLoop()
	while running do
		if os.time() - t0 >= CFG.RUNTIME then
			fileOut(string.format("[%s] RUNTIME-Limit (%ds) erreicht — beende.", nowStr(), CFG.RUNTIME))
			break
		end
		local scan
		local isProbe = probeFlag and (os.clock() - lastProbeScan) > CFG.PROBE_COOLDOWN
		if isProbe then
			probeFlag = false
			lastProbeScan = os.clock()
			scan = fullScan("PROBE")
		else
			scan = fullScan("SCAN")
		end
		scanNo = scanNo + 1
		totals.scans = totals.scans + 1
		lastScan = scan

		if not scan.valid then
			if scan.truncated then totals.truncated = totals.truncated + 1 else totals.partial = totals.partial + 1 end
			invalidLine(scan)
			lastScanInfo = "Scan#" .. scanNo .. " UNGUELTIG (kein Diff)"
			-- Punkt 30: gezielter Root-Alive-Check auch bei ungueltigem Scan
			-- (nur Hinweis-Log, KEIN State/kein prev-Ersatz)
			if tradeRootRef then
				local alive, why = rootAlive()
				if not alive then
					fileOut(string.format("[%s] INFO (ungueltiger Scan): tradeRoot id=%d lebt NICHT mehr (%s) — kein CLOSED-State aus ungueltigem Scan",
						nowStr(), tradeRootId, tostring(why)))
				end
			end
		else
			totals.validScans = totals.validScans + 1
			if baselineReady and prevRows then
				local NEW, CHANGED, REMOVED = classifyDiff(prevRows, scan.rows)
				if #NEW + #CHANGED + #REMOVED > 0 then
					totals.new = totals.new + #NEW
					totals.changed = totals.changed + #CHANGED
					totals.removed = totals.removed + #REMOVED
					writeDiffSection(scan, NEW, CHANGED, REMOVED)
				end
				prevRows = scan.rows
				detectState(scan)
			end
			local txtN = 0
			for _, r in ipairs(scan.rows) do if not r.frame and not r.isSG then txtN = txtN + 1 end end
			lastScanInfo = string.format("Scan#%d obj=%d hits=%d %dms", scanNo, #scan.rows, #scan.hits, scan.durMs)
			rebindWatchers(scan) -- NUR bei gueltigen Scans (Punkt 8)
		end

		-- Punkt 13: Container periodisch neu suchen
		if scanNo % CFG.CONTAINER_RESCAN_EVERY == 0 then
			local before = #containers
			buildContainers()
			bindRoots()
			if #containers ~= before then
				fileOut(string.format("[%s] INFO: Container-Rescan: %d -> %d Container", nowStr(), before, #containers))
			end
		end

		if PANEL then
			pcall(function()
				local st = history[#history] and history[#history].state or "-"
				PANEL.Box.Txt.Text = "PC99 v7 | " .. lastScanInfo ..
					"\nState: " .. st .. " | NEW/CH/REM: " .. totals.new .. "/" .. totals.changed .. "/" .. totals.removed ..
					"\nWatcher: " .. #watchCons .. " | " .. filePath
			end)
		end

		local waited = 0
		while running and waited < CFG.SCAN_INTERVAL do
			if os.time() - t0 >= CFG.RUNTIME then break end
			if probeFlag and (os.clock() - lastProbeScan) > CFG.PROBE_COOLDOWN then break end
			task.wait(0.1)
			waited = waited + 0.1
		end
		-- Punkt 43: Zeit-Flush, damit Crash/Beendigung nicht alles verliert
		if os.clock() - lastFlushClock >= CFG.FLUSH_EVERY_S then forceFlush() end
	end
end

-- Ablauf ---------------------------------------------------------
print("[PC99] DEEP-SCAN v7 startet. Datei: " .. filePath)

-- Bootstrap in xpcall: ein Fehler beim Start ist jetzt SICHTBAR
-- (Panel + Datei), statt dass das Script still stirbt und das
-- Panel fuer immer auf "starte..." stehen bleibt.
local function mainBootstrap()
	execProbe()
	buildContainers()
	headerOut()
	bindRoots()

local lp = Players.LocalPlayer
if not lp then
	print("[PC99] Warte auf LocalPlayer (max 15s)...")
	for _ = 1, 75 do
		lp = Players.LocalPlayer
		if lp then break end
		task.wait(0.2)
	end
	if lp then
		pcall(function()
			local pg = lp:FindFirstChild("PlayerGui") or lp:WaitForChild("PlayerGui", 8)
			if pg then addContainer("PlayerGui", pg, "PlayerGui"); contProbe.PlayerGui = "ok (nachtraeglich)" end
		end)
		bindRoots()
	end
end
if not Players.LocalPlayer then
	fileOut("WARNUNG: kein LocalPlayer nach 15s — PlayerGui NICHT im Scan.")
end

	local baselineOk = runBaseline()
	if baselineOk and prevRows then dumpBaseline(prevRows) end

	if PANEL then
		pcall(function()
			PANEL.Box.Txt.Text = "PC99 v7 | Baseline: " .. (baselineStable and "STABIL" or (baselineOk and "UNSTABIL" or "FEHLER")) ..
				"\nJetzt Alt-Trade oeffnen (read-only Test)"
		end)
	end
end

local okB, errB = xpcall(mainBootstrap, function(e)
	if debug and type(debug.traceback) == "function" then return debug.traceback(tostring(e), 2) end
	return tostring(e)
end)
if not okB then
	fileOut("!! FEHLER beim Start (Bootstrap): " .. tostring(errB))
	forceFlush()
	print("[PC99] FEHLER beim Start: " .. tostring(errB))
	if PANEL then
		pcall(function()
			PANEL.Box.Txt.Text = "PC99 v7 FEHLER beim Start:\n" .. tostring(errB)
		end)
	end
end

-- Notfall-Abschluss (Punkt 43): falls summary() SELBST fehlschlaegt,
-- schreibt ein minimaler, robuster Schreiber die Kernzahlen.
local function emergencySummary(why)
	pcall(function()
		local s = table.concat({
			"PC99 v7 NOTFALL-ABSCHLUSS: summary() fehlgeschlagen: " .. tostring(why),
			string.format("Scans=%d valid=%d partial=%d truncated=%d NEW/CH/REM=%d/%d/%d",
				totals.scans, totals.validScans, totals.partial, totals.truncated,
				totals.new, totals.changed, totals.removed),
			"States: " .. tostring(#history) .. " | Datei: " .. filePath,
			"Daten bis zum letzten Flush sind in der Datei.",
		}, "\n") .. "\n"
		if fileInit then pcall(appendfile, filePath, s)
		else pcall(writefile, "pc99_scan7_notfall.txt", s) end
		print("[PC99] NOTFALL-ABSCHLUSS geschrieben (summary fehlgeschlagen): " .. tostring(why))
	end)
	stopAll()
end

task.spawn(function()
	local ok, errm = xpcall(mainLoop, function(e)
		if debug and type(debug.traceback) == "function" then return debug.traceback(tostring(e), 2) end
		return tostring(e)
	end)
	if not ok then
		fileOut("!! FEHLER im Hauptloop (Scan-Daten bis hier sind in der Datei): " .. tostring(errm))
	end
	forceFlush()
	local okS, errS = pcall(summary)
	if not okS then emergencySummary(errS) end
	print("[PC99] v7 beendet. Report: " .. filePath)
end)

print("[PC99] v7 bereit. Stop: getgenv().PC99_SCAN7.stop()")
