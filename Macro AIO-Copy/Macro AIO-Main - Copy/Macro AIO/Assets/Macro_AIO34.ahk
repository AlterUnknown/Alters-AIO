#Requires AutoHotkey v2.0
#Include Gdip_All.ahk
#SingleInstance Force
#MaxThreadsPerHotkey 100
Persistent
; AHK's default is to pop up a warning dialog once 70 hotkey activations land
; inside a 2000ms window (A_MaxHotkeysPerInterval=70, A_HotkeyInterval=2000).
; A fast clicker/recorder can trip that, so turn the dialog off entirely.
A_HotkeyInterval := 0
A_MaxHotkeysPerInterval := 99000000
CoordMode("Mouse", "Screen")

TraySetIcon(A_ScriptDir "\AutoClicker_icon.png")

; =====================================================
;   AUTOCLICKER — compact wide UI, three modes, stats
; =====================================================
; Modes (selected via the MODE dropdown on the Clicker tab):
;   - Normal      : fires a real mouse click at the cursor.
;   - Window Focus: posts clicks to the exact child control
;                   under a chosen point without activating
;                   that window/tab.
;   - Key Press   : "presses" a chosen letter/number key
;                   instead of clicking. Goes to whichever
;                   window currently has keyboard focus.
; Reality check: background-tab clicking inside one browser
; window is not possible (tabs share one HWND and get
; throttled when inactive) — pop the target into its own
; window first. Some anti-cheat systems (e.g. Roblox/Hyperion)
; also detect and block synthetic input by design.
; =====================================================

dataFile := A_ScriptDir "\AutoClicker_data.ini"

; ---------- State ----------
clicking       := false
sessionClicks  := 0
toggleKey      := "F6"
targetHwnd     := 0
targetTopHwnd  := 0
targetTitle    := ""
clickX         := 0
clickY         := 0
pickMode       := false
winList        := Map()

cpsWindowStart := 0
cpsWindowCount := 0
sessionPeakCps := 0.0
appStartTick   := A_TickCount

; ---------- High Speed Mode state ----------
hsFreq        := 0      ; high-res counter ticks per second
hsLast        := 0      ; counter reading at the previous High Speed tick
hsCarry       := 0.0    ; fractional clicks still owed from earlier ticks
hsRunClicks   := 0      ; clicks fired since this run started (for Fixed Count)

; ---------- Recorder state ----------
recording            := false
playing              := false
recordedEvents       := []
recordStartTick      := 0
lastMoveX            := 0
lastMoveY            := 0
playbackIndex        := 1
playbackStartTick    := 0
playbackRepeatsTotal := 1
playbackRepeatsDone  := 0
playbackPaused       := false
playbackPauseStartTick := 0
recordingFilePath    := ""
recKeyList           := BuildRecordableKeyList()

; ---------- Vision (GDI+) state ----------
visionBitmap    := 0
visionOffsetX   := 0
visionOffsetY   := 0
visionWinX      := 0
visionWinY      := 0
visionFoundX    := -1
visionFoundY    := -1
visionWatching  := false
visionThumbFlip := false

; ---------- Games: Fisch auto-shake state ----------
fischShaking    := false
fischImagePath  := A_ScriptDir "\Assets\fisch_shake.png"
bobBackpackImagePath := A_ScriptDir "\Assets\bobfarm_backpack.png"
bobSearchImagePath   := A_ScriptDir "\Assets\bobfarm_search.png"
bobEquipImagePath    := A_ScriptDir "\Assets\bobfarm_equip.png"
bobXImagePath        := A_ScriptDir "\Assets\bobfarm_x.png"
bobXFailsafeImagePath := A_ScriptDir "\Assets\bobfarm_x_failsafe.png"
bobPortalImagePath   := A_ScriptDir "\Assets\bobfarm_portal.png"
bobPortalFailsafeImagePath := A_ScriptDir "\Assets\bobfarm_portal_failsafe.png"
bobNahImagePath      := A_ScriptDir "\Assets\bobfarm_nah.png"
bobPlayImagePath     := A_ScriptDir "\Assets\bobfarm_play.png"
bobPlayFailsafeImagePath := A_ScriptDir "\Assets\bobfarm_play_failsafe.png"
bobFarmRunning    := false
bobFarmPhase      := "setup"   ; "setup" (runs once) then "loop" (repeats)
bobFarmStepIdx    := 1
bobFarmState      := "acting"  ; "acting" (performing/polling current step) or "cooldown" (1s gap before next step)
bobFarmCooldownAt := 0
bobFarmHoldStart  := 0
bobFarmNahCooldownAt := 0
bobFarmXCooldownAt := 0
bobFarmActionGapMs := 1000     ; the "1s interval between actions" the user asked for
bobFarmResetStreak := 0        ; counts consecutive "portal not found" resets in a row
bobFarmResetStreakMax := 10    ; after 10 consecutive portal misses, rejoin instead of shutting the macro off
bobFarmHeldKey := ""           ; tracks whichever key is currently physically held down, so it can always be force-released
bobFarmServerHopActive := false
bobFarmServerHopStartTick := 0
bobFarmServerHopState := "idle"   ; idle, wait_play, wait_restart
bobFarmServerHopPreNudged := false   ; one-shot flag: nudge mouse once, 3s before searching for Play
bobFarmServerHopReason := ""    ; "scheduled" or "portal_failsafe"
bobFarmBackpackWaitStart := 0
bobFarmBackpackTimeoutMs := 15000  ; if Backpack is not found in 15s, skip the replica setup and start the main loop
fischRegionX1   := 0
fischRegionY1   := 0
fischRegionX2   := 0
fischRegionY2   := 0
fischShakeStart := 0
fischLastFoundTick := 0

; ---------- Games: Default tab (user-defined custom image detectors) ----------
; Starts completely empty — the user adds their own reference images and picks
; what each one should do. Nothing is enabled until the user turns it on.
MAX_DEFAULT_SLOTS := 5
defaultDetectors := []   ; each entry: Map("used",bool,"enabled",bool,"imgPath",str,"actionType",str,"actionParam",str,"cooldownUntil",int, plus control refs)

lifetimeClicks   := Integer(IniRead(dataFile, "Stats", "LifetimeClicks", 0))
totalSessions    := Integer(IniRead(dataFile, "Stats", "TotalSessions", 0)) + 1
lifetimeRuntime  := Integer(IniRead(dataFile, "Stats", "LifetimeRuntimeSec", 0))
longestSession   := Integer(IniRead(dataFile, "Stats", "LongestSessionSec", 0))
peakCpsEver      := Float(IniRead(dataFile, "Stats", "PeakCpsEver", 0))
IniWrite(totalSessions, dataFile, "Stats", "TotalSessions")

cpsTestRunning     := false
cpsTestClicks      := 0
cpsTestEndTick     := 0
cpsCooldownEndTick := 0

; ---------- Dashboard state ----------
dashboardImagePath := IniRead(dataFile, "Dashboard", "ImagePath", "")
currentPage := ""

; ---------- Macro playback keybind (persisted so it survives a restart) ----------
playbackToggleKey := IniRead(dataFile, "Hotkeys", "PlaybackKey", "F4")

; ---------- Theme ----------
; Diavolo-inspired pink-only palette: neutral charcoal base, ivory text,
; and multiple shades of pink for accents, buttons, and states.
bg      := "101010"   ; neutral near-black (no purple tint)
fg      := "F7EAF0"   ; soft ivory-pink text
sub     := "B995A8"   ; muted pink-gray secondary text
accent  := "E0568C"   ; core Diavolo pink
green   := "D66A9C"   ; running/positive state, still pink
red     := "FF4F7B"   ; stop/danger state, pink-red

; ================= GUI =================
MyGui := Gui("+Resize", "Macro AIO")
gdipToken := Gdip_Startup()
gdipButtons := []
MyGui.BackColor := bg
MyGui.SetFont("s9 c" fg, "Bahnschrift")

; ---- Header ----
MyGui.SetFont("s13 bold c" fg, "Bahnschrift")
hdrTitle := MyGui.AddText("x16 y12 w300 h24", "MACRO AIO")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
chkTop := MyGui.AddCheckbox("x621 y16 w130 c" sub, "Always on top")
chkTop.OnEvent("Click", (*) => WinSetAlwaysOnTop(chkTop.Value, MyGui))

; ============================================================
; LEFT SIDEBAR NAVIGATION
; ============================================================
; Flat list of native buttons, indented per nesting level. Clicking
; one calls ShowPage(key), which shows only that page's controls
; (collected into the `pages` map below as each page is built) and
; re-labels the active button with a leading marker.
navLabels := Map()
navButtons := Map()

MakeNavButton(key, x, y, w, label) {
    global navLabels, navButtons, MyGui, bg, fg
    navLabels[key] := label
    btn := MyGui.AddText("x" x " y" y " w" w " h26 Background" bg " c" fg " 0x200", label)
    btn.SetFont("s9")
    btn.OnEvent("Click", (*) => ShowPage(key))
    navButtons[key] := btn
    return btn
}

MakeNavButton("dashboard", 8, 44, 128, "Dashboard")

MyGui.SetFont("s8 bold c" accent, "Bahnschrift")
MyGui.AddText("x12 y78 w128", "CLICKER")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
MakeNavButton("autoclicker", 8, 96, 128, "Auto Clicker")
MakeNavButton("cpstest", 20, 124, 116, "CPS Test")
MakeNavButton("sessionstats", 20, 152, 116, "Session Stats")

MyGui.SetFont("s8 bold c" accent, "Bahnschrift")
MyGui.AddText("x12 y186 w128", "MACRO")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
MakeNavButton("macro", 8, 204, 128, "Macro")
MakeNavButton("macroprofiles", 20, 232, 116, "Macro Profiles")

MyGui.SetFont("s8 bold c" accent, "Bahnschrift")
MyGui.AddText("x12 y266 w128", "MISC")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
MakeNavButton("games", 8, 284, 128, "Games")
MakeNavButton("vision", 8, 312, 128, "Vision")

; ============================================================
; PAGE — DASHBOARD
; ============================================================
MyGui.SetFont("s20 bold c" accent, "Bahnschrift")
dashTitle := MyGui.AddText("x145 y70 w600 h34 Center", "MACRO AIO")
MyGui.SetFont("s10 c" sub, "Bahnschrift")
dashCredit := MyGui.AddText("x145 y108 w600 h20 Center", "Created by AlterUnknown")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

dashPicFrame := MyGui.AddGroupBox("x145 y140 w600 h250 c" fg, "")
dashDefaultPic := A_ScriptDir "\AutoClicker_icon.png"
dashInitialPic := (dashboardImagePath != "" && FileExist(dashboardImagePath)) ? dashboardImagePath : dashDefaultPic
dashPic := MyGui.AddPicture("x155 y150 w580 h200 Border", dashInitialPic)
MyGui.SetFont("s9 c" sub, "Bahnschrift")
dashPicHint := MyGui.AddText("x155 y358 w400 c" sub, dashboardImagePath != "" ? dashboardImagePath : "No custom picture set.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
dashBtnPic := MakeStyledButton(MyGui, 565, 354, 170, 28, "Set Dashboard Picture...", (*) => ChooseDashboardImage(), "A43B68", "6F2147")

pageDashboard := [dashTitle, dashCredit, dashPicFrame, dashPic, dashPicHint, dashBtnPic]


; -- Left column: mode + swappable mode panel --
anon_pageautoclickertxt_1 := MyGui.AddText("x145 y70 w280 c" accent, "MODE")
anon_pageautoclickertxt_1.SetFont("s9 bold")
ddMode := MyGui.AddDropDownList("x145 y88 w280 c000000", ["Normal (click at cursor)", "Window Focus (background click)", "Key Press (auto-press key)"])
ddMode.Choose(1)

; -- Mode panel: exactly one of these three is visible at a time --
grpNormal := MyGui.AddGroupBox("x145 y120 w280 h190 c" sub, "Normal Click")
txtNormalHint1 := MyGui.AddText("x157 y150 w260 c" sub, "Clicks fire at your current mouse")
txtNormalHint2 := MyGui.AddText("x157 y166 w260 c" sub, "cursor position, using the button")
txtNormalHint3 := MyGui.AddText("x157 y182 w260 c" sub, "and type set under CLICK OPTIONS.")

grpTarget := MyGui.AddGroupBox("x145 y120 w280 h190 c" sub, "Target Window")
txtWinLabel := MyGui.AddText("x157 y142 w70", "Window")
ddWinList := MyGui.AddDropDownList("x231 y140 w140 c000000", ["(click Refresh)"])
btnRefresh := MakeStyledButton(MyGui, 375, 139, 40, 22, "⟳", (*) => RefreshWindowList(), "7D1F46", "52132F")
btnUseSelected := MakeStyledButton(MyGui, 157, 172, 126, 26, "Use Selected", (*) => UseSelectedWindow(), "A43B68", "6F2147")
btnPickSpot    := MakeStyledButton(MyGui, 289, 172, 126, 26, "Set Spot (F3)", (*) => BeginPickSpot(), "C34778", "86254F")
txtTarget := MyGui.AddText("x157 y204 w268 c" sub, "No window selected")
txtCoords := MyGui.AddText("x157 y222 w268 c" sub, "Click position: -")

grpKey := MyGui.AddGroupBox("x145 y120 w280 h190 c" sub, "Key To Press")
txtKeyLabel := MyGui.AddText("x157 y146 w120", "Key")
ddKeyPress := MyGui.AddDropDownList("x157 y166 w128 c000000", KeyPressOptions())
ddKeyPress.Choose(1)
txtKeyHint1 := MyGui.AddText("x157 y200 w260 c" sub, "The clicker will press this key")
txtKeyHint2 := MyGui.AddText("x157 y216 w260 c" sub, "on your keyboard (down + up) instead")
txtKeyHint3 := MyGui.AddText("x157 y232 w260 c" sub, "of performing a mouse click.")

btnTest := MakeStyledButton(MyGui, 157, 258, 258, 24, "Test Click Once", (*) => TestClick(), "E0568C", "8C2F57")

anon_pageautoclickertxt_2 := MyGui.AddText("x145 y320 w280 c" accent, "HOTKEY  /  SAFETY")
anon_pageautoclickertxt_2.SetFont("s9 bold")
anon_pageautoclickertxt_3 := MyGui.AddText("x145 y340 w80", "Toggle key")
; A Hotkey control (not a fixed dropdown) so the toggle key can be ANY key
; or combo — letters, numbers, Ctrl/Alt/Shift combos, mouse side buttons, etc.
ddHotkey := MyGui.AddHotkey("x228 y338 w70 c000000", "F6")
chkFailsafe := MyGui.AddCheckbox("x145 y368 w280 c" fg, "Failsafe: stop at bottom of screen")
chkFailsafe.Value := 1

; -- Right column: interval + options + status --
anon_pageautoclickertxt_4 := MyGui.AddText("x453 y70 w280 c" accent, "CLICK INTERVAL")
anon_pageautoclickertxt_4.SetFont("s9 bold")
anon_pageautoclickertxt_5 := MyGui.AddText("x453 y92 w50", "Hours")
eHours := MyGui.AddEdit("x498 y90 w40 Center c000000", "0")
anon_pageautoclickertxt_6 := MyGui.AddText("x545 y92 w50", "Min")
eMins := MyGui.AddEdit("x580 y90 w40 Center c000000", "0")
anon_pageautoclickertxt_7 := MyGui.AddText("x453 y120 w50", "Sec")
eSecs := MyGui.AddEdit("x498 y118 w40 Center c000000", "0")
anon_pageautoclickertxt_8 := MyGui.AddText("x545 y120 w50", "Ms")
eMs := MyGui.AddEdit("x580 y118 w40 Center c000000", "50")

anon_pageautoclickertxt_9 := MyGui.AddText("x453 y155 w280 c" accent, "CLICK OPTIONS")
anon_pageautoclickertxt_9.SetFont("s9 bold")
anon_pageautoclickertxt_10 := MyGui.AddText("x453 y177 w60", "Button")
ddButton := MyGui.AddDropDownList("x508 y175 w80 c000000", ["Left", "Right", "Middle"])
ddButton.Choose(1)
anon_pageautoclickertxt_11 := MyGui.AddText("x596 y177 w40", "Type")
ddType := MyGui.AddDropDownList("x638 y175 w95 c000000", ["Single", "Double"])
ddType.Choose(1)

anon_pageautoclickertxt_12 := MyGui.AddText("x453 y207 w60", "Repeat")
ddRepeat := MyGui.AddDropDownList("x508 y205 w110 c000000", ["Until Stopped", "Fixed Count"])
ddRepeat.Choose(1)
eCount := MyGui.AddEdit("x623 y207 w45 Center c000000", "10")
eCount.Enabled := false

MyGui.SetFont("s12 bold c" red, "Bahnschrift")
txtStatus := MyGui.AddText("x453 y248 w280 h22 Center", "STOPPED")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

MyGui.SetFont("s10 bold c" fg, "Bahnschrift")
btnStart := MakeStyledButton(MyGui, 453, 276, 135, 34, "Start (F6)", (*) => StartClicking(), "E0568C", "9C2C5D")
btnStop := MakeStyledButton(MyGui, 598, 276, 135, 34, "Stop (F6)", (*) => StopClicking(), "FF4F7B", "A62E50")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

txtHint := MyGui.AddText("x453 y318 w280 c" sub, "Window Focus won't reach a background tab.")
anon_pageautoclickertxt_13 := MyGui.AddText("x453 y334 w280 c" sub, "Key Press sends to whatever window has focus.")

; -- High Speed Mode --
chkHighSpeed := MyGui.AddCheckbox("x453 y358 w150 c" fg, "High Speed Mode")
anon_hs_label := MyGui.AddText("x612 y360 w62 c" fg, "Target CPS")
eHsCps := MyGui.AddEdit("x676 y356 w56 Center c000000", "200")
anon_hs_hint := MyGui.AddText("x453 y384 w280 h48 c" sub, "Breaks the ~64 CPS timer limit by sending clicks in batches. Uses Target CPS (max 10000) instead of the interval fields.")


pageAutoClicker := [anon_pageautoclickertxt_1,ddMode,grpNormal,txtNormalHint1,txtNormalHint2,txtNormalHint3,grpTarget,txtWinLabel,ddWinList,btnRefresh,btnUseSelected,btnPickSpot,txtTarget,txtCoords,grpKey,txtKeyLabel,ddKeyPress,txtKeyHint1,txtKeyHint2,txtKeyHint3,btnTest,anon_pageautoclickertxt_2,anon_pageautoclickertxt_3,ddHotkey,chkFailsafe,anon_pageautoclickertxt_4,anon_pageautoclickertxt_5,eHours,anon_pageautoclickertxt_6,eMins,anon_pageautoclickertxt_7,eSecs,anon_pageautoclickertxt_8,eMs,anon_pageautoclickertxt_9,anon_pageautoclickertxt_10,ddButton,anon_pageautoclickertxt_11,ddType,anon_pageautoclickertxt_12,ddRepeat,eCount,txtStatus,btnStart,btnStop,txtHint,anon_pageautoclickertxt_13]
pageAutoClicker.Push(chkHighSpeed, anon_hs_label, eHsCps, anon_hs_hint)
; ============================================================
; TAB 2 — SESSION STATISTICS (compact grid)
; ============================================================

grpSession := MyGui.AddGroupBox("x145 y66 w190 h100 c" accent, "SESSION CLICKS")
MyGui.SetFont("s26 bold c" fg, "Bahnschrift")
txtSessionClicks := MyGui.AddText("x157 y88 w170 h40", "0")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_sessionclicks_label := MyGui.AddText("x157 y142 w170", "clicks this session")
grpLive := MyGui.AddGroupBox("x343 y66 w120 h100 c" fg, "LIVE CPS")
MyGui.SetFont("s20 bold c" accent, "Bahnschrift")
txtLiveCps := MyGui.AddText("x353 y90 w100 h34", "0.0")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_livecps_label := MyGui.AddText("x353 y142 w100", "per sec")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

grpPeakEver := MyGui.AddGroupBox("x471 y66 w278 h100 c" fg, "LIFETIME PEAK CPS")
MyGui.SetFont("s20 bold c" fg, "Bahnschrift")
txtPeakEver := MyGui.AddText("x483 y90 w260 h34", "0.0 CPS")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

; Returns [groupbox, textControl] so callers can hide both together.
MakeStatCard(x, y, w, h, label) {
    global MyGui, fg
    grp := MyGui.AddGroupBox("x" x " y" y " w" w " h" h " c" fg, label)
    MyGui.SetFont("s15 bold c" fg, "Bahnschrift")
    t := MyGui.AddText("x" (x+12) " y" (y+22) " w" (w-24) " h" (h-30), "-")
    MyGui.SetFont("s9 c" fg, "Bahnschrift")
    return [grp, t]
}

avgCard := MakeStatCard(202, 176, 190, 64, "AVG CPS")
peakCard := MakeStatCard(400, 176, 120, 64, "PEAK CPS")
durationCard := MakeStatCard(528, 176, 278, 64, "SESSION TIME")
lifeClicksCard := MakeStatCard(202, 250, 190, 64, "LIFETIME CLICKS")
totalSessionsCard := MakeStatCard(400, 250, 120, 64, "SESSIONS")
longestSessionCard := MakeStatCard(528, 250, 278, 64, "LONGEST SESSION")
txtAvgCps := avgCard[2], txtPeakCps := peakCard[2], txtDuration := durationCard[2]
txtLifeClicks := lifeClicksCard[2], txtTotalSessions := totalSessionsCard[2], txtLongestSession := longestSessionCard[2]

btnResetSession := MakeStyledButton(MyGui, 145, 326, 190, 30, "Reset Session", (*) => ResetSession(), "A43B68", "6F2147")
btnResetLifetime := MakeStyledButton(MyGui, 343, 326, 248, 30, "Reset Lifetime Stats", (*) => ResetLifetime(), "C34778", "86254F")
btnCopyStats := MakeStyledButton(MyGui, 599, 326, 150, 30, "Copy Stats", (*) => CopyStats(), "E0568C", "8C2F57")

pageSessionStats := [grpSession, txtSessionClicks, anon_sessionclicks_label, grpLive, txtLiveCps, anon_livecps_label
    , grpPeakEver, txtPeakEver, avgCard[1], avgCard[2], peakCard[1], peakCard[2], durationCard[1], durationCard[2]
    , lifeClicksCard[1], lifeClicksCard[2], totalSessionsCard[1], totalSessionsCard[2], longestSessionCard[1], longestSessionCard[2]
    , btnResetSession, btnResetLifetime, btnCopyStats]

; ============================================================
; TAB 3 — CPS TEST (compact)
; ============================================================

anon_pagecpstesttxt_1 := MyGui.AddText("x145 y66 w580 c" sub, "Click the box as fast as you can. This tests your raw clicking speed - it never fires the autoclicker.")

anon_pagecpstesttxt_2 := MyGui.AddText("x145 y92 w60", "Duration")
ddCpsDuration := MyGui.AddDropDownList("x208 y90 w110 c000000", ["5 seconds", "10 seconds", "15 seconds", "30 seconds"])
ddCpsDuration.Choose(1)

MyGui.SetFont("s15 bold c" fg, "Bahnschrift")
btnCpsBox := MakeStyledButton(MyGui, 145, 122, 580, 150, "Click here to start", (*) => CpsTestClick(), "7D1F46", "421125")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

MyGui.SetFont("s11 bold c" fg, "Bahnschrift")
txtCpsTimer := MyGui.AddText("x145 y282 w280 h22", "Time left: -")
txtCpsCount := MyGui.AddText("x445 y282 w280 h22", "Clicks: 0")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

grpCpsResult := MyGui.AddGroupBox("x145 y312 w580 h70 c" accent, "RESULT")
MyGui.SetFont("s14 bold c" fg, "Bahnschrift")
txtCpsResult := MyGui.AddText("x157 y336 w560 h32", "Run a test to see your CPS.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")


pageCpsTest := [anon_pagecpstesttxt_1,anon_pagecpstesttxt_2,ddCpsDuration,btnCpsBox,txtCpsTimer,txtCpsCount,grpCpsResult,txtCpsResult]
; ============================================================
; TAB 4 — RECORDER  (compact toolbar-style macro UI)
; ============================================================
; Compact toolbar layout inspired by the supplied reference image.
; Recorder settings are kept on the main Macro page — there is no
; separate Preferences window anymore. Saving creates a named profile.
MyGui.SetFont("s9 c" fg, "Bahnschrift")

macroStatusText := MyGui.AddText("x145 y66 w430 h18 c" sub, "Idle — ready")
macroSpeedText := MyGui.AddText("x665 y66 w60 h18 Right c" sub, "100%")

ddMacroRecording := MyGui.AddDropDownList("x145 y88 w330 h24 c000000", ["New recording"])
ddMacroRecording.Choose(1)

btnMacroImport := MakeStyledButton(MyGui, 483, 88, 76, 24, "Import", (*) => DoLoadRecording(), "7D1F46", "52132F")
btnMacroExport := MakeStyledButton(MyGui, 563, 88, 76, 24, "Export", (*) => DoExportRecording(), "A43B68", "6F2147")
btnMacroDelete := MakeStyledButton(MyGui, 643, 88, 76, 24, "Del", (*) => ClearRecording(), "FF4F7B", "A62E50")

btnMacroSave := MakeStyledButton(MyGui, 145, 122, 76, 34, "Save", (*) => SaveRecordingCurrent(), "A43B68", "6F2147")
btnMacroRecord := MakeStyledButton(MyGui, 225, 122, 76, 34, "● Rec", (*) => ToggleRecording(), "E0568C", "8C2F57")
btnMacroPlay := MakeStyledButton(MyGui, 305, 122, 76, 34, "▶ Play", (*) => StartPlayback(), "C34778", "81254F")
btnMacroPause := MakeStyledButton(MyGui, 385, 122, 76, 34, "Ⅱ Pause", (*) => TogglePlaybackPause(), "D66A9C", "8E3C64")
btnMacroStop := MakeStyledButton(MyGui, 465, 122, 76, 34, "■ Stop", (*) => StopMacroActivity(), "C34778", "81254F")

; Main-page recorder settings. Kept compact and isolated from the status row
; so no labels/controls overlap when the GUI repaints or is resized.
chkRecordMoves := MyGui.AddCheckbox("x550 y122 w175 c" fg, "Record mouse movement")
chkRecordMoves.Value := 1
MyGui.SetFont("s8 c" sub, "Bahnschrift")
txtSpeedLabel := MyGui.AddText("x550 y151 w38 h18", "Speed")
eSpeed := MyGui.AddEdit("x592 y149 w48 h22 Center c000000", "100")
txtSpeedPct := MyGui.AddText("x644 y151 w18 h18", "%")
txtRepeatLabel := MyGui.AddText("x550 y181 w38 h18", "Repeat")
ddPlayRepeat := MyGui.AddDropDownList("x592 y178 w133 h22 c000000", ["Play Once", "Repeat 3x", "Repeat 5x", "Repeat 10x", "Loop Until Stopped"])
ddPlayRepeat.Choose(1)
MyGui.SetFont("s9 c" fg, "Bahnschrift")

txtRecCount := MyGui.AddText("x145 y166 w270 c" sub, "Events: 0")
txtRecDuration := MyGui.AddText("x420 y166 w120 Right c" sub, "Duration: 00:00:00")
txtRecFile := MyGui.AddText("x145 y208 w574 c" sub, "No recording yet.")

; Playback keybind - record a combo in the box, then click Save to bind it.
; (Same explicit-save pattern as the Typing Test keybind, since relying on
; the box's live Change event alone wasn't reliable.) It's also written to
; the data ini so it's remembered the next time the app is opened.
MyGui.SetFont("s8 c" sub, "Bahnschrift")
txtPlaybackKeyLabel := MyGui.AddText("x145 y238 w110 h24", "Playback keybind")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
ddPlaybackHotkey := MyGui.AddHotkey("x255 y236 w80 c000000", playbackToggleKey)
btnPlaybackSaveKey := MakeStyledButton(MyGui, 343, 234, 110, 26, "Save Keybind", (*) => UpdatePlaybackHotkey(), "C34778", "81254F")
txtPlaybackKeyStatus := MyGui.AddText("x459 y238 w260 h24 c" sub, "Toggle key: " playbackToggleKey)

pageMacro := [macroStatusText,macroSpeedText,ddMacroRecording,btnMacroImport,btnMacroExport,btnMacroDelete
    ,btnMacroSave,btnMacroRecord,btnMacroPlay,btnMacroPause,btnMacroStop
    ,chkRecordMoves,txtSpeedLabel,eSpeed,txtSpeedPct,txtRepeatLabel,ddPlayRepeat
    ,txtRecCount,txtRecDuration,txtRecFile
    ,txtPlaybackKeyLabel,ddPlaybackHotkey,btnPlaybackSaveKey,txtPlaybackKeyStatus]
; ============================================================
; TAB 5 — PROFILES  (save/load named setups + recordings)
; ============================================================

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
anon_pagemacroprofilestxt_1 := MyGui.AddText("x145 y66 w580", "PROFILE MANAGER")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_pagemacroprofilestxt_2 := MyGui.AddText("x145 y86 w580 h38", "Save your current mode, interval, hotkey, target window and recording as a named profile so you can jump between games/tasks instantly.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

anon_pagemacroprofilestxt_3 := MyGui.AddText("x145 y128 w80", "Profile")
ddProfiles := MyGui.AddDropDownList("x213 y126 w300 c000000", ["(no profiles saved)"])
btnRefreshProfiles := MakeStyledButton(MyGui, 521, 125, 40, 22, "⟳", (*) => RefreshProfileList(), "A43B68", "6F2147")

btnSaveProfile := MakeStyledButton(MyGui, 145, 162, 180, 30, "Save Current As...", (*) => DoSaveProfile(), "A43B68", "6F2147")
btnLoadProfile := MakeStyledButton(MyGui, 331, 162, 180, 30, "Load Selected", (*) => DoLoadProfile(), "C34778", "81254F")
btnDeleteProfile := MakeStyledButton(MyGui, 517, 162, 130, 30, "Delete Selected", (*) => DoDeleteProfile(), "FF4F7B", "A62E50")

txtProfileStatus := MyGui.AddText("x145 y204 w580 c" sub, "No profile loaded.")

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
anon_pagemacroprofilestxt_4 := MyGui.AddText("x145 y240 w580", "WHAT GETS SAVED")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_pagemacroprofilestxt_5 := MyGui.AddText("x145 y260 w580 h70", "Mode, interval, button/click type, repeat count, hotkey, failsafe, key-to-press, target window title, and the full recorder macro (mouse moves, clicks, keystrokes) currently in the Recorder tab.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")



pageMacroProfiles := [anon_pagemacroprofilestxt_1,anon_pagemacroprofilestxt_2,anon_pagemacroprofilestxt_3,ddProfiles,btnRefreshProfiles,btnSaveProfile,btnLoadProfile,btnDeleteProfile,txtProfileStatus,anon_pagemacroprofilestxt_4,anon_pagemacroprofilestxt_5]
; ============================================================
; TAB 6 — VISION  (GDI+ background capture + pixel color search)
; ============================================================

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
anon_pagevisiontxt_1 := MyGui.AddText("x145 y66 w580", "VISION — PIXEL COLOR SEARCH")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_pagevisiontxt_2 := MyGui.AddText("x145 y86 w580 h34", "Captures the Target Window set on the Clicker tab (Window Focus mode) using GDI+ — works even if it's partially covered by other windows.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

grpCapture := MyGui.AddGroupBox("x145 y122 w280 h250 c" accent, "Capture")
btnCapture := MakeStyledButton(MyGui, 157, 146, 256, 28, "Capture Now", (*) => DoCaptureVision(), "A43B68", "6F2147")
txtCaptureInfo := MyGui.AddText("x157 y180 w256 c" sub, "No capture yet.")
picVisionThumb := MyGui.AddPicture("x157 y200 w256 h150 Border", "")

grpColorSearch := MyGui.AddGroupBox("x453 y122 w280 h250 c" fg, "Find Color")
anon_pagevisiontxt_3 := MyGui.AddText("x465 y146 w80", "Color (hex)")
eColorHex := MyGui.AddEdit("x545 y144 w110 c000000", "FF0000")
anon_pagevisiontxt_4 := MyGui.AddText("x465 y174 w80", "Tolerance")
eTolerance := MyGui.AddEdit("x545 y172 w60 Center c000000", "20")
btnFindColor := MakeStyledButton(MyGui, 465, 202, 256, 28, "Find Color In Capture", (*) => DoFindColor(), "C34778", "81254F")
txtFindResult := MyGui.AddText("x465 y236 w256 h34 c" sub, "Not searched yet.")
btnMoveMouse := MakeStyledButton(MyGui, 465, 274, 124, 26, "Move Mouse There", (*) => DoMoveToFound(), "D66A9C", "8E3C64")
btnClickFound := MakeStyledButton(MyGui, 597, 274, 124, 26, "Click (Background)", (*) => DoClickFound(), "E0568C", "8C2F57")
chkAutoWatch := MyGui.AddCheckbox("x465 y306 w256 c" fg, "Auto-watch: capture + search every")
eWatchInterval := MyGui.AddEdit("x465 y326 w50 Center c000000", "500")
anon_pagevisiontxt_5 := MyGui.AddText("x519 y328 w40", "ms")
btnWatch := MakeStyledButton(MyGui, 573, 324, 148, 26, "Start Watching", (*) => ToggleWatch(), "FF5C9D", "A52B62")



pageVision := [anon_pagevisiontxt_1,anon_pagevisiontxt_2,grpCapture,btnCapture,txtCaptureInfo,picVisionThumb,grpColorSearch,anon_pagevisiontxt_3,eColorHex,anon_pagevisiontxt_4,eTolerance,btnFindColor,txtFindResult,btnMoveMouse,btnClickFound,chkAutoWatch,eWatchInterval,anon_pagevisiontxt_5,btnWatch]
; (Typing Test used to be its own page here — it's now built further down,
; inside Games > Slap Battles, since that's where it's actually used.)
; ============================================================
; TAB 7 — GAMES  (per-game macros, starting with Fisch)
; ============================================================

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
anon_pagegamestxt_1 := MyGui.AddText("x145 y66 w580", "GAMES")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_pagegamestxt_2 := MyGui.AddText("x145 y86 w580 h20", "Pick a game on the left, then enable its macro.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

grpGamesList := MyGui.AddGroupBox("x145 y118 w140 h310 c" fg, "Games")
lbGames := MyGui.AddListBox("x157 y142 w116 h276 Background" bg " c" fg, ["Default", "Fisch", "Slap Battles", "Typing Test", "BTD6"])
lbGames.Choose(2)
lbGames.OnEvent("Change", (*) => UpdateGamesUI())

; ---- Default: user-defined custom image detectors ----
grpDefault := MyGui.AddGroupBox("x301 y118 w424 h310 c" accent, "Default — Custom Detectors")
btnDefaultAdd := MakeStyledButton(MyGui, 313, 142, 150, 24, "+ Add Detector...", (*) => DoAddDefaultDetector(), "C34778", "81254F")
txtDefaultStatus := MyGui.AddText("x313 y172 w404 h32 c" sub, "No detectors yet — add one above.")
defaultPanel := [grpDefault, btnDefaultAdd, txtDefaultStatus]

defaultSlotRowY := 210
Loop MAX_DEFAULT_SLOTS {
    slotIdx := A_Index
    rowY := defaultSlotRowY + (slotIdx - 1) * 42

    picSlot := MyGui.AddPicture("x313 y" rowY " w34 h34 Border Hidden", A_ScriptDir "\AutoClicker_icon.png")
    chkSlotEnable := MyGui.AddCheckbox("x357 y" (rowY + 9) " w40 c" fg " Hidden", "On")
    MyGui.SetFont("s8 c" fg, "Bahnschrift")
    ddSlotAction := MyGui.AddDropDownList("x405 y" (rowY + 7) " w110 Choose1 Hidden", ["Click", "Press Key", "Key Sequence"])
    eSlotParam := MyGui.AddEdit("x519 y" (rowY + 7) " w90 c000000 Hidden", "Enter")
    MyGui.SetFont("s9 c" fg, "Bahnschrift")
    btnSlotRemove := MakeStyledButton(MyGui, 623, rowY + 5, 24, 24, "X", RemoveDefaultDetectorSlot.Bind(slotIdx), "C34778", "81254F")
    btnSlotRemove.Opt("Hidden")

    chkSlotEnable.OnEvent("Click", ToggleDefaultDetectorSlot.Bind(slotIdx))
    ddSlotAction.OnEvent("Change", DefaultActionTypeChanged.Bind(slotIdx))

    defaultDetectors.Push(Map(
        "used", false, "enabled", false, "imgPath", "", "actionType", "Click", "actionParam", "Enter"
        , "cooldownUntil", 0, "foundX", 0, "foundY", 0
        , "pic", picSlot, "chk", chkSlotEnable, "dd", ddSlotAction, "param", eSlotParam, "remove", btnSlotRemove
    ))
    defaultPanel.Push(picSlot, chkSlotEnable, ddSlotAction, eSlotParam, btnSlotRemove)
}

grpFisch := MyGui.AddGroupBox("x301 y118 w424 h310 c" accent, "Fisch — Auto Shake")
chkFischEnable := MyGui.AddCheckbox("x313 y142 w200 c" fg, "Enable")
txtFischStatus := MyGui.AddText("x313 y168 w404 h18 c" sub, "Disabled.")

fischInitialPic := FileExist(fischImagePath) ? fischImagePath : A_ScriptDir "\AutoClicker_icon.png"
picFischRef := MyGui.AddPicture("x313 y194 w90 h90 Border", fischInitialPic)
MyGui.SetFont("s8 c" sub, "Bahnschrift")
anon_pagegamestxt_3 := MyGui.AddText("x413 y194 w312 h60", "Reference image — this is what the macro looks for on screen. When it's spotted, ENTER gets spammed until it disappears.")
btnFischChangeImg := MakeStyledButton(MyGui, 413, 256, 180, 24, "Change Reference Image...", (*) => DoChangeFischImage(), "A43B68", "6F2147")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

anon_pagegamestxt_4 := MyGui.AddText("x313 y296 w90", "Sensitivity")
eFischVariation := MyGui.AddEdit("x413 y294 w60 Center c000000", "15")
MyGui.SetFont("s8 c" sub, "Bahnschrift")
anon_pagegamestxt_5 := MyGui.AddText("x481 y296 w244", "0 = exact match, higher = more forgiving")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

anon_pagegamestxt_6 := MyGui.AddText("x313 y324 w90", "Check every")
eFischInterval := MyGui.AddEdit("x413 y322 w60 Center c000000", "150")
anon_pagegamestxt_7 := MyGui.AddText("x477 y324 w30", "ms")
anon_pagegamestxt_8 := MyGui.AddText("x517 y324 w80", "Min spam")
eFischMaxBurst := MyGui.AddEdit("x599 y322 w58 Center c000000", "4000")
anon_pagegamestxt_9 := MyGui.AddText("x659 y324 w30", "ms")

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
anon_pagegamestxt_10 := MyGui.AddText("x313 y352 w404", "SEARCH REGION (narrower = way less lag)")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
txtFischRegion := MyGui.AddText("x313 y372 w404 c" sub, "Not set — currently scanning the WHOLE screen (slow).")
btnFischTL := MakeStyledButton(MyGui, 313, 392, 196, 24, "Set Top-Left = Mouse Pos", (*) => SetFischRegionCorner("TL"), "C34778", "81254F")
btnFischBR := MakeStyledButton(MyGui, 513, 392, 212, 24, "Set Bottom-Right = Mouse Pos", (*) => SetFischRegionCorner("BR"), "E0568C", "8C2F57")
fischPanel := [grpFisch,chkFischEnable,txtFischStatus,picFischRef,anon_pagegamestxt_3,btnFischChangeImg,anon_pagegamestxt_4,eFischVariation,anon_pagegamestxt_5,anon_pagegamestxt_6,eFischInterval,anon_pagegamestxt_7,anon_pagegamestxt_8,eFischMaxBurst,anon_pagegamestxt_9,anon_pagegamestxt_10,txtFischRegion,btnFischTL,btnFischBR]

; ---- Slap Battles: Bob Farm (step sequence, more steps to come) ----
grpSlapBattles := MyGui.AddGroupBox("x301 y118 w424 h360 c" accent, "Bob Farm")
chkFarmEnable := MyGui.AddCheckbox("x313 y142 w260 c" fg, "Enable (F3)")
txtFarmStatus := MyGui.AddText("x313 y168 w404 h18 c" sub, "Disabled.")

farmImgs := [["Backpack", bobBackpackImagePath], ["Search", bobSearchImagePath], ["Equip", bobEquipImagePath]
    , ["X", bobXImagePath], ["Portal", bobPortalImagePath], ["Nah", bobNahImagePath]]
farmPicCtrls := []
farmColX := 313
for pair in farmImgs {
    lbl := pair[1], imgPath := pair[2]
    p := MyGui.AddPicture("x" farmColX " y194 w60 h60 Border", FileExist(imgPath) ? imgPath : A_ScriptDir "\AutoClicker_icon.png")
    farmPicCtrls.Push(p)
    farmColX += 68
}
MyGui.SetFont("s8 c" sub, "Bahnschrift")
farmColX := 313
for pair in farmImgs {
    t := MyGui.AddText("x" farmColX " y256 w60 Center", pair[1])
    farmPicCtrls.Push(t)
    farmColX += 68
}
MyGui.SetFont("s9 c" fg, "Bahnschrift")

anon_farmtxt_4 := MyGui.AddText("x313 y280 w90", "Spam E count")
eFarmESpamCount := MyGui.AddEdit("x413 y278 w50 Center c000000", "3")
chkFarmServerHop := MyGui.AddCheckbox("x313 y306 w300 c" fg, "Server Hop every 10 min")
anon_farmtxt_5 := MyGui.AddText("x313 y330 w404 h140 c" sub, "Once: Backpack -> Search -> `"replica`" -> Equip -> X -> Esc,r,Enter (0.3s gaps). Then loops: Portal (resets via Esc,r,Enter if not seen for 2s) -> hold S 2s -> spam E immediately -> Esc,r,Enter (0.3s gaps). 1s between every other action. `"Nah`" is clicked any time it's seen. Server Hop: Esc -> L -> Enter, wait 20s, click either Play button, wait 20s, then restart the whole sequence. Portal failsafe: after 10 consecutive portal resets, rejoin instead of shutting off.")

chkFarmEnable.OnEvent("Click", (*) => ToggleBobFarm())
chkFarmServerHop.OnEvent("Click", (*) => UpdateBobFarmServerHopSetting())
Hotkey("F3", (*) => ToggleBobFarmHotkey(), "On")

slapBattlesPanel := [grpSlapBattles, chkFarmEnable, txtFarmStatus, anon_farmtxt_4, eFarmESpamCount, chkFarmServerHop, anon_farmtxt_5]
slapBattlesPanel.Push(farmPicCtrls*)

; ---- Typing Test: its own entry in the Games list, right under Slap Battles ----
grpTypingTest := MyGui.AddGroupBox("x301 y118 w424 h310 c" accent, "Typing Test")
MyGui.SetFont("s8 c" sub, "Bahnschrift")
anon_slaptypingtxt_1 := MyGui.AddText("x313 y142 w400 h32", "Type (or paste) a phrase, set a target WPM, and it's typed out at that pace - handy for anything that checks for human-like typing instead of an instant paste.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
ttPhrase := MyGui.AddEdit("x313 y178 w400 h70 c000000", "")
anon_slaptypingtxt_2 := MyGui.AddText("x313 y258 w70 h24", "Target WPM")
ttWPM := MyGui.AddEdit("x383 y256 w50 Center c000000", "60")
btnTTStart := MakeStyledButton(MyGui, 471, 254, 110, 26, "Start Typing", (*) => StartTypingTest(), "C34778", "81254F")
btnTTStop := MakeStyledButton(MyGui, 591, 254, 90, 26, "Stop", (*) => StopTypingTest(), "6B2D45", "401A29")

; Keybind gets its own row with an explicit Save button - press record a
; combo in the box, then click Save to actually bind it. (Relying on the
; box's live Change event alone wasn't reliable enough.)
anon_slaptypingtxt_3 := MyGui.AddText("x313 y292 w70 h24", "Keybind")
ttHotkey := MyGui.AddHotkey("x383 y290 w80 c000000", "F10")
btnTTSaveKey := MakeStyledButton(MyGui, 471, 288, 90, 26, "Save Keybind", (*) => UpdateTypingTestHotkey(), "C34778", "81254F")
ttStatus := MyGui.AddText("x313 y324 w400 h18 c" sub, "Idle. Toggle key: F10")

chkHumanMode := MyGui.AddCheckbox("x313 y350 w400 c" fg, "Human Mode (WPM fluctuates a bit, less robotic)")
chkTypos := MyGui.AddCheckbox("x331 y374 w380 c" fg, "Enable Typos (occasionally mistype a letter, then backspace and fix it)")
chkTypos.Enabled := false
chkHumanMode.OnEvent("Click", (*) => UpdateHumanModeUI())
chkTypos.OnEvent("Click", (*) => UpdateHumanModeUI())

typingTestPanel := [grpTypingTest, anon_slaptypingtxt_1, ttPhrase, anon_slaptypingtxt_2, ttWPM, btnTTStart, btnTTStop
    , anon_slaptypingtxt_3, ttHotkey, btnTTSaveKey, ttStatus, chkHumanMode, chkTypos]

; ---- BTD6: auto monkey placer ----
; Each monkey in the list is placed in priority order (top row first):
;   press its BTD6 hotkey -> click the chosen spot -> click the monkey to
;   select it -> press the upgrade key for its path N times.
; Drag the "≡" handle on a row to change its priority.
MAX_BTD_SLOTS := 8
BTD_ROW_H := 30
btdRowY0 := 212
btdData := []          ; ordered list (index = priority) of Map(monkey,x,y,path,tiers,wait)
btdSlots := []         ; fixed pool of row controls, filled from btdData by BtdRender()
btdRunning := false
btdRendering := false
btdDragFrom := 0
btdPickSlot := 0
btdToggleKey := ""
btdMonkeyNames := ["Dart Monkey", "Boomerang Monkey", "Bomb Shooter", "Tack Shooter", "Ice Monkey", "Glue Gunner"
    , "Sniper Monkey", "Monkey Sub", "Monkey Buccaneer", "Monkey Ace", "Heli Pilot", "Mortar Monkey", "Dartling Gunner"
    , "Wizard Monkey", "Super Monkey", "Ninja Monkey", "Alchemist", "Druid", "Banana Farm", "Engineer Monkey"
    , "Spike Factory", "Monkey Village", "Hero"]
; BTD6 default tower hotkeys
btdMonkeyKeys := Map("Dart Monkey", "q", "Boomerang Monkey", "w", "Bomb Shooter", "e", "Tack Shooter", "r"
    , "Ice Monkey", "t", "Glue Gunner", "y", "Sniper Monkey", "z", "Monkey Sub", "x", "Monkey Buccaneer", "c"
    , "Monkey Ace", "v", "Heli Pilot", "b", "Mortar Monkey", "n", "Dartling Gunner", "m", "Wizard Monkey", "a"
    , "Super Monkey", "s", "Ninja Monkey", "d", "Alchemist", "f", "Druid", "g", "Banana Farm", "h"
    , "Engineer Monkey", "l", "Spike Factory", "j", "Monkey Village", "k", "Hero", "u")
btdPathNames := ["Top", "Mid", "Bottom"]
; AFK Deflation loop reference images
btdImgOk       := A_ScriptDir "\Assets\btd_ok.png"
btdImgNext     := A_ScriptDir "\Assets\btd_next.png"
btdImgHome     := A_ScriptDir "\Assets\btd_home.png"
btdImgPlayGlow := A_ScriptDir "\Assets\btd_play_glow.png"
btdImgMeadow   := A_ScriptDir "\Assets\btd_map_meadow.png"
btdImgEasy     := A_ScriptDir "\Assets\btd_easy.png"
btdImgDeflation := A_ScriptDir "\Assets\btd_deflation.png"
btdImgStart    := A_ScriptDir "\Assets\btd_start.png"
btdImgSpeed    := A_ScriptDir "\Assets\btd_speed.png"
btdImgLevelUp := A_ScriptDir "\Assets\btd_level_up.png"
btdInLevelUp := false
btdAfkImages := Map("btd_ok.png", btdImgOk, "btd_next.png", btdImgNext, "btd_home.png", btdImgHome
    , "btd_play_glow.png", btdImgPlayGlow, "btd_map_meadow.png", btdImgMeadow, "btd_easy.png", btdImgEasy
    , "btd_deflation.png", btdImgDeflation, "btd_start.png", btdImgStart, "btd_speed.png", btdImgSpeed, "btd_level_up.png", btdImgLevelUp)

grpBtd := MyGui.AddGroupBox("x301 y118 w424 h422 c" accent, "BTD6 — Auto Monkey Placer")
btnBtdAdd := MakeStyledButton(MyGui, 313, 142, 140, 24, "+  Add Monkey", (*) => BtdAddMonkey(), "C34778", "81254F")
btnBtdStart := MakeStyledButton(MyGui, 461, 142, 100, 24, "Start", (*) => StartBtd(), "E0568C", "8C2F57")
btnBtdStop := MakeStyledButton(MyGui, 569, 142, 100, 24, "Stop", (*) => StopBtd(), "6B2D45", "401A29")
txtBtdStatus := MyGui.AddText("x313 y172 w404 h18 c" sub, "Idle.")

MyGui.SetFont("s8 bold c" accent, "Bahnschrift")
btdHdr1 := MyGui.AddText("x313 y194 w34", "Pri.")
btdHdr2 := MyGui.AddText("x351 y194 w104", "Monkey")
btdHdr3 := MyGui.AddText("x459 y194 w90", "Position")
btdHdr4 := MyGui.AddText("x553 y194 w62", "Path")
btdHdr5 := MyGui.AddText("x619 y194 w28", "Tier")
btdHdr6 := MyGui.AddText("x649 y194 w34", "Wait s")

btdPanel := [grpBtd, btnBtdAdd, btnBtdStart, btnBtdStop, txtBtdStatus, btdHdr1, btdHdr2, btdHdr3, btdHdr4, btdHdr5, btdHdr6]

Loop MAX_BTD_SLOTS {
    slotIdx := A_Index
    rowY := btdRowY0 + (slotIdx - 1) * BTD_ROW_H
    MyGui.SetFont("s9 bold c" sub, "Bahnschrift")
    sHandle := MyGui.AddText("x313 y" rowY " w34 h22 0x200 Hidden", "≡ " slotIdx)
    sHandle.OnEvent("Click", (*) => 0)   ; gives the text control mouse input so the drag handler can see it
    MyGui.SetFont("s8 c" fg, "Bahnschrift")
    sDd := MyGui.AddDropDownList("x351 y" rowY " w104 c000000 Choose1 Hidden", btdMonkeyNames)
    sPos := MakeStyledButton(MyGui, 459, rowY, 90, 22, "Set Pos", BtdBeginPick.Bind(slotIdx), "C34778", "81254F")
    sPos.Opt("Hidden")
    sPath := MyGui.AddDropDownList("x553 y" rowY " w62 c000000 Choose1 Hidden", btdPathNames)
    sTier := MyGui.AddEdit("x619 y" rowY " w26 h22 Center c000000 Limit1 Hidden", "5")
    sWait := MyGui.AddEdit("x649 y" rowY " w30 h22 Center c000000 Limit3 Hidden", "0")
    sRemove := MakeStyledButton(MyGui, 683, rowY, 24, 22, "X", BtdRemoveMonkey.Bind(slotIdx), "C34778", "81254F")
    sRemove.Opt("Hidden")

    sDd.OnEvent("Change", BtdFieldChanged.Bind(slotIdx))
    sPath.OnEvent("Change", BtdFieldChanged.Bind(slotIdx))
    sTier.OnEvent("Change", BtdFieldChanged.Bind(slotIdx))
    sWait.OnEvent("Change", BtdFieldChanged.Bind(slotIdx))

    btdSlots.Push(Map("handle", sHandle, "dd", sDd, "pos", sPos, "path", sPath, "tier", sTier, "wait", sWait, "remove", sRemove))
    btdPanel.Push(sHandle, sDd, sPos, sPath, sTier, sWait, sRemove)
}

MyGui.SetFont("s8 c" sub, "Bahnschrift")
btdKeysLbl := MyGui.AddText("x313 y458 w230", "Upgrade keys  (Top / Mid / Bottom)")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
eBtdKeyTop := MyGui.AddEdit("x313 y474 w34 Center c000000", "1")
eBtdKeyMid := MyGui.AddEdit("x351 y474 w34 Center c000000", "2")
eBtdKeyBot := MyGui.AddEdit("x389 y474 w34 Center c000000", "3")
btdDelayLbl := MyGui.AddText("x445 y477 w90", "Action delay")
eBtdDelay := MyGui.AddEdit("x535 y474 w50 Center c000000", "300")
btdDelayMs := MyGui.AddText("x589 y477 w24", "ms")

btdKeybindLbl := MyGui.AddText("x313 y503 w54", "Keybind")
ttBtdHotkey := MyGui.AddHotkey("x369 y500 w70 c000000", "F7")
btnBtdSaveKey := MakeStyledButton(MyGui, 447, 498, 90, 26, "Save Keybind", (*) => UpdateBtdHotkey(), "C34778", "81254F")
chkBtdAfk := MyGui.AddCheckbox("x549 y502 w170 c" fg, "AFK Deflation loop")

MyGui.SetFont("s8 c" sub, "Bahnschrift")
btdHint := MyGui.AddText("x313 y526 w404 h12", "Drag ≡ to reorder · Set Pos: hover + F8 · AFK loop uses Assets\btd_*.png")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

btdPanel.Push(btdKeysLbl, eBtdKeyTop, eBtdKeyMid, eBtdKeyBot, btdDelayLbl, eBtdDelay, btdDelayMs
    , btdKeybindLbl, ttBtdHotkey, btnBtdSaveKey, chkBtdAfk, btdHint)

OnMessage(0x201, BtdOnLButtonDown)

BtdIndexOf(arr, val) {
    for i, v in arr {
        if v = val
            return i
    }
    return 1
}

; Fills the row controls from btdData and shows only the rows that are in use
; (and only while the BTD6 entry is the selected game).
BtdRender() {
    global btdData, btdSlots, btdMonkeyNames, btdPathNames, btdRendering, lbGames
    btdRendering := true
    try {
        onPage := (lbGames.Text = "BTD6")
        for i, s in btdSlots {
            used := i <= btdData.Length
            if used {
                m := btdData[i]
                s["handle"].Text := "≡ " i
                s["dd"].Choose(BtdIndexOf(btdMonkeyNames, m["monkey"]))
                s["pos"].Text := m["x"] >= 0 ? m["x"] "," m["y"] : "Set Pos"
                s["path"].Choose(BtdIndexOf(btdPathNames, m["path"]))
                s["tier"].Text := m["tiers"]
                s["wait"].Text := m["wait"]
            }
            for key in ["handle", "dd", "pos", "path", "tier", "wait", "remove"]
                try s[key].Opt((onPage && used) ? "-Hidden" : "+Hidden")
        }
    } finally {
        btdRendering := false
    }
}

BtdAddMonkey() {
    global btdData, txtBtdStatus, MAX_BTD_SLOTS
    if btdData.Length >= MAX_BTD_SLOTS {
        txtBtdStatus.Text := "Max of " MAX_BTD_SLOTS " monkeys reached — remove one first."
        return
    }
    btdData.Push(Map("monkey", "Dart Monkey", "x", -1, "y", -1, "path", "Top", "tiers", 5, "wait", 0))
    txtBtdStatus.Text := "Added monkey #" btdData.Length " — pick its type, then click Set Pos."
    BtdRender()
}

BtdRemoveMonkey(slot, *) {
    global btdData
    if slot > btdData.Length
        return
    btdData.RemoveAt(slot)
    BtdRender()
}

; Copies a row's dropdowns/edits back into btdData whenever the user changes them.
BtdFieldChanged(slot, *) {
    global btdData, btdSlots, btdRendering
    if btdRendering || slot > btdData.Length
        return
    s := btdSlots[slot]
    m := btdData[slot]
    m["monkey"] := s["dd"].Text
    m["path"] := s["path"].Text
    m["tiers"] := Max(1, Min(5, HsInt(s["tier"].Text, 5)))
    m["wait"] := Max(0, HsInt(s["wait"].Text, 0))
}

; ---- Position picking: hover the spot in-game and press F8 (Esc cancels) ----
BtdBeginPick(slot, *) {
    global btdPickSlot, btdData
    if slot > btdData.Length
        return
    btdPickSlot := slot
    ToolTip("Hover the spot for monkey #" slot " and press F8. Esc cancels.")
    SetTimer(BtdWatchPick, 50)
}

BtdWatchPick() {
    global btdPickSlot, btdData, txtBtdStatus
    if !btdPickSlot {
        SetTimer(BtdWatchPick, 0)
        ToolTip()
        return
    }
    if GetKeyState("F8", "P") {
        MouseGetPos(&mx, &my)
        slot := btdPickSlot
        btdPickSlot := 0
        SetTimer(BtdWatchPick, 0)
        ToolTip()
        if slot <= btdData.Length {
            btdData[slot]["x"] := mx
            btdData[slot]["y"] := my
            txtBtdStatus.Text := "Monkey #" slot " position set: " mx "," my
            BtdRender()
        }
    } else if GetKeyState("Escape", "P") {
        btdPickSlot := 0
        SetTimer(BtdWatchPick, 0)
        ToolTip()
    }
}

; ---- Drag-to-reorder priority (grab a row's ≡ handle, drop on another row) ----
BtdOnLButtonDown(wParam, lParam, msg, hwnd) {
    global btdSlots, btdData, btdDragFrom, lbGames, currentPage
    if currentPage != "games" || lbGames.Text != "BTD6"
        return
    for i, s in btdSlots {
        if i <= btdData.Length && hwnd = s["handle"].Hwnd {
            btdDragFrom := i
            SetTimer(BtdDragTick, 30)
            return
        }
    }
}

BtdDragTick() {
    global btdDragFrom, btdData, MyGui, btdRowY0, BTD_ROW_H
    if !btdDragFrom {
        SetTimer(BtdDragTick, 0)
        return
    }
    MouseGetPos(&mx, &my)
    try WinGetClientPos(&gx, &gy, , , "ahk_id " MyGui.Hwnd)
    catch {
        gy := 0
    }
    target := Floor((my - gy - btdRowY0) / BTD_ROW_H) + 1
    target := Max(1, Min(btdData.Length, target))
    if GetKeyState("LButton", "P") {
        ToolTip("Move monkey #" btdDragFrom " to priority " target)
        return
    }
    SetTimer(BtdDragTick, 0)
    ToolTip()
    from := btdDragFrom
    btdDragFrom := 0
    if target != from && from <= btdData.Length {
        item := btdData.RemoveAt(from)
        btdData.InsertAt(target, item)
        BtdRender()
    }
}

; ---- Running the build ----
; Sleeps in small slices so Stop / the kill switch can interrupt immediately.
BtdSleep(ms, checkLevelUp := true) {
    global btdRunning
    endTick := A_TickCount + ms
    while A_TickCount < endTick {
        if !btdRunning
            throw Error("BTD stopped")
        if checkLevelUp
            BtdCheckLevelUp()
        Sleep(Min(20, Max(1, endTick - A_TickCount)))
    }
    if !btdRunning
        throw Error("BTD stopped")
}

; Called from every normal wait in the macro. If the "Level Up!" banner is on
; screen, spam-click it for 4 seconds (one click every 0.5s), then carry on.
; (Waits inside a key press / click sequence skip this check so a held key or
; half-finished click is never interrupted.)
BtdCheckLevelUp() {
    global btdInLevelUp, btdImgLevelUp, txtBtdStatus
    static lastCheck := 0
    if btdInLevelUp || A_TickCount - lastCheck < 500
        return
    lastCheck := A_TickCount
    if !FileExist(btdImgLevelUp)
        return
    if !BtdFindImage(btdImgLevelUp, &fx, &fy)
        return
    btdInLevelUp := true
    try {
        oldStatus := txtBtdStatus.Text
        txtBtdStatus.Text := "Level Up! — spam clicking for 4s..."
        startTick := A_TickCount
        while A_TickCount - startTick < 4000 {
            BtdClickAt(fx, fy)
            BtdSleep(500, false)
        }
        txtBtdStatus.Text := oldStatus
    } finally {
        btdInLevelUp := false
    }
}

BtdTapKey(key) {
    key := Trim(key)
    if key = ""
        return
    Send("{" key " down}")
    BtdSleep(40, false)
    Send("{" key " up}")
}

BtdClickAt(x, y) {
    ; Tiny real movement first - games often ignore a click when the cursor
    ; is already sitting on the exact target pixel.
    MouseMove(x, y, 0)
    BtdSleep(40, false)
    MouseMove(x + 1, y, 0)
    BtdSleep(20, false)
    MouseMove(x, y, 0)
    BtdSleep(40, false)
    Click("Left Down")
    BtdSleep(40, false)
    Click("Left Up")
}

ToggleBtd(*) {
    global btdRunning
    if btdRunning
        StopBtd()
    else
        StartBtd()
}

StopBtd() {
    global btdRunning, txtBtdStatus
    if !btdRunning
        return
    btdRunning := false
    txtBtdStatus.Text := "Stopping..."
}

; Places every monkey in the plan (priority order): hotkey -> click spot ->
; click monkey to select -> press the path's upgrade key N times.
BtdPlaceAll(plan, delayMs, pathKeys) {
    global btdMonkeyKeys, txtBtdStatus
    total := plan.Length
    for i, m in plan {
        prefix := "(" i "/" total ") " m["monkey"] ": "
        if m["wait"] > 0 {
            txtBtdStatus.Text := prefix "waiting " m["wait"] "s..."
            BtdSleep(m["wait"] * 1000)
        }

        txtBtdStatus.Text := prefix "placing..."
        BtdTapKey(btdMonkeyKeys[m["monkey"]])
        BtdSleep(delayMs)
        BtdClickAt(m["x"], m["y"])
        BtdSleep(delayMs + 200)

        if m["monkey"] = "Hero" {
            BtdSleep(delayMs)
            continue   ; heroes have no upgrade paths
        }

        txtBtdStatus.Text := prefix "selecting..."
        BtdClickAt(m["x"], m["y"])
        BtdSleep(delayMs)

        upKey := pathKeys[m["path"]]
        loop m["tiers"] {
            txtBtdStatus.Text := prefix m["path"] " path upgrade " A_Index "/" m["tiers"] "..."
            BtdTapKey(upKey)
            BtdSleep(delayMs)
        }
        BtdSleep(delayMs)
    }
}

; ---- Image helpers (AFK loop) ----
; Half the image's size, so clicks land on the button's centre instead of its top-left corner.
BtdImgHalfSize(path) {
    static cache := Map()
    if cache.Has(path)
        return cache[path]
    w := 0, h := 0
    try {
        pBm := Gdip_CreateBitmapFromFile(path)
        if pBm {
            w := Gdip_GetImageWidth(pBm)
            h := Gdip_GetImageHeight(pBm)
            Gdip_DisposeImage(pBm)
        }
    }
    cache[path] := [w // 2, h // 2]
    return cache[path]
}

; One screen scan. Returns true (and sets fx/fy to the image centre) if found.
BtdFindImage(path, &fx, &fy, variation := 40) {
    fx := 0, fy := 0
    found := false
    try found := ImageSearch(&ix, &iy, 0, 0, A_ScreenWidth, A_ScreenHeight, "*" variation " " path)
    if !found
        return false
    half := BtdImgHalfSize(path)
    fx := ix + half[1]
    fy := iy + half[2]
    return true
}

; Waits (up to timeoutMs) for the image to appear, then clicks its centre.
BtdWaitClick(path, timeoutMs, label, variation := 40) {
    global txtBtdStatus
    endTick := A_TickCount + timeoutMs
    loop {
        if BtdFindImage(path, &fx, &fy, variation) {
            BtdClickAt(fx, fy)
            BtdSleep(600)
            return
        }
        if A_TickCount >= endTick
            throw Error("Couldn't find the " label " button after " (timeoutMs // 1000) "s - stopped.")
        BtdSleep(300)
    }
}

; Waits (up to timeoutMs) for the image to appear, without clicking.
BtdWaitSee(path, timeoutMs, label, variation := 40) {
    endTick := A_TickCount + timeoutMs
    loop {
        if BtdFindImage(path, &fx, &fy, variation)
            return
        if A_TickCount >= endTick
            throw Error("Never saw " label " after " (timeoutMs // 1000) "s - stopped.")
        BtdSleep(500)
    }
}

BtdMissingAfkImages() {
    global btdAfkImages
    missing := ""
    for name, path in btdAfkImages {
        if !FileExist(path)
            missing .= "`n  Assets\" name
    }
    return missing
}

; ---- AFK Deflation loop ----
; First launch: place monkeys right away (be on the map, before pressing Start).
; Then: Start -> Speed up -> wait for NEXT -> NEXT -> Home -> Play (glowing) ->
; Monkey Meadow -> Easy -> Deflation -> OK -> wait for the map -> place monkeys -> repeat.
BtdAfkLoop(plan, delayMs, pathKeys) {
    global txtBtdStatus, btdImgOk, btdImgNext, btdImgHome, btdImgPlayGlow, btdImgMeadow
    global btdImgEasy, btdImgDeflation, btdImgStart, btdImgSpeed

    runNum := 0
    loop {
        runNum += 1
        tag := "AFK run " runNum ": "

        txtBtdStatus.Text := tag "placing monkeys..."
        BtdPlaceAll(plan, delayMs, pathKeys)

        txtBtdStatus.Text := tag "pressing Start..."
        BtdWaitClick(btdImgStart, 30000, "Start")
        txtBtdStatus.Text := tag "speeding up..."
        BtdWaitClick(btdImgSpeed, 15000, "Speed up")

        ; Wait for the victory screen (NEXT). Gives up after 40 minutes in case the run was lost.
        waitStart := A_TickCount
        loop {
            if BtdFindImage(btdImgNext, &fx, &fy) {
                BtdClickAt(fx, fy)
                BtdSleep(800)
                break
            }
            elapsed := (A_TickCount - waitStart) // 1000
            if elapsed > 2400
                throw Error("No victory screen after 40 minutes - stopped (run may have been lost).")
            txtBtdStatus.Text := tag "playing... " (elapsed // 60) "m " Mod(elapsed, 60) "s"
            BtdSleep(1000)
        }

        txtBtdStatus.Text := tag "Home..."
        BtdWaitClick(btdImgHome, 30000, "Home")
        txtBtdStatus.Text := tag "opening map select..."
        BtdWaitClick(btdImgPlayGlow, 40000, "Play (map select)", 60)
        txtBtdStatus.Text := tag "Monkey Meadow..."
        BtdWaitClick(btdImgMeadow, 30000, "Monkey Meadow")
        txtBtdStatus.Text := tag "Easy..."
        BtdWaitClick(btdImgEasy, 20000, "Easy")
        txtBtdStatus.Text := tag "Deflation..."
        BtdWaitClick(btdImgDeflation, 20000, "Deflation")
        txtBtdStatus.Text := tag "OK..."
        BtdWaitClick(btdImgOk, 20000, "OK")

        txtBtdStatus.Text := tag "waiting for the map to load..."
        BtdWaitSee(btdImgStart, 90000, "the Start button (map load)")
        BtdSleep(1500)
    }
}

StartBtd() {
    global btdRunning, btdData, txtBtdStatus, chkBtdAfk
    global eBtdKeyTop, eBtdKeyMid, eBtdKeyBot, eBtdDelay
    if btdRunning
        return
    if btdData.Length = 0 {
        txtBtdStatus.Text := "Add at least one monkey first."
        return
    }
    for i, m in btdData {
        if m["x"] < 0 {
            txtBtdStatus.Text := "Monkey #" i " (" m["monkey"] ") has no position — click its Set Pos."
            return
        }
    }
    afk := chkBtdAfk.Value
    if afk {
        missing := BtdMissingAfkImages()
        if missing != "" {
            MsgBox("AFK mode needs these reference images (extract the Assets folder next to the script):" missing, "Macro AIO", 48)
            return
        }
    }

    pathKeys := Map("Top", eBtdKeyTop.Text, "Mid", eBtdKeyMid.Text, "Bottom", eBtdKeyBot.Text)
    delayMs := Max(50, HsInt(eBtdDelay.Text, 300))
    plan := []
    for m in btdData
        plan.Push(m.Clone())

    btdRunning := true
    try {
        loop 3 {
            txtBtdStatus.Text := "Starting in " (4 - A_Index) "s — click into BTD6 now..."
            BtdSleep(1000)
        }
        if afk {
            BtdAfkLoop(plan, delayMs, pathKeys)   ; runs until stopped
        } else {
            BtdPlaceAll(plan, delayMs, pathKeys)
            total := plan.Length
            txtBtdStatus.Text := "Done — placed " total " monkey" (total = 1 ? "" : "s") "."
        }
    } catch as err {
        if err.Message = "BTD stopped"
            txtBtdStatus.Text := "Stopped."
        else
            txtBtdStatus.Text := "BTD6 macro: " err.Message
    }
    btdRunning := false
}

; Same explicit-save pattern as the other keybinds (click Save after recording the combo).
UpdateBtdHotkey(*) {
    global btdToggleKey, ttBtdHotkey, txtBtdStatus
    newKey := ttBtdHotkey.Value
    if newKey = "" {
        if btdToggleKey != ""
            try Hotkey(btdToggleKey, ToggleBtd, "Off")
        btdToggleKey := ""
        txtBtdStatus.Text := "No keybind set — record one above, then click Save Keybind."
        return
    }
    if newKey = btdToggleKey {
        txtBtdStatus.Text := "Idle. Toggle key: " btdToggleKey " (already saved)."
        return
    }
    try {
        Hotkey(newKey, ToggleBtd, "On")
        if btdToggleKey != ""
            try Hotkey(btdToggleKey, ToggleBtd, "Off")
        btdToggleKey := newKey
        txtBtdStatus.Text := "Idle. Toggle key: " btdToggleKey
    } catch {
        txtBtdStatus.Text := "Couldn't bind that key/combo — try a different one."
    }
}

UpdateGamesUI() {
    global lbGames, fischPanel, slapBattlesPanel, defaultPanel, typingTestPanel, btdPanel
    sel := lbGames.Text
    for ctrl in defaultPanel
        try ctrl.Opt(sel = "Default" ? "-Hidden" : "+Hidden")
    for ctrl in fischPanel
        try ctrl.Opt(sel = "Fisch" ? "-Hidden" : "+Hidden")
    for ctrl in slapBattlesPanel
        try ctrl.Opt(sel = "Slap Battles" ? "-Hidden" : "+Hidden")
    for ctrl in typingTestPanel
        try ctrl.Opt(sel = "Typing Test" ? "-Hidden" : "+Hidden")
    for ctrl in btdPanel
        try ctrl.Opt(sel = "BTD6" ? "-Hidden" : "+Hidden")
    if sel = "Default"
        RefreshDefaultSlotVisibility()
    if sel = "BTD6"
        BtdRender()
}
UpdateGamesUI()

pageGames := [anon_pagegamestxt_1,anon_pagegamestxt_2,grpGamesList,lbGames]
pageGames.Push(defaultPanel*)
pageGames.Push(fischPanel*)
pageGames.Push(slapBattlesPanel*)
pageGames.Push(typingTestPanel*)
pageGames.Push(btdPanel*)
; ============================================================
; PAGE SWITCHING
; ============================================================
pages := Map("dashboard", pageDashboard, "autoclicker", pageAutoClicker
    , "cpstest", pageCpsTest, "sessionstats", pageSessionStats
    , "macro", pageMacro, "macroprofiles", pageMacroProfiles
    , "games", pageGames, "vision", pageVision)

; ---- Per-page scroll (safety net for any page taller than the window) ----
; Base (x,y) of every control on every page, captured once so scrolling can
; always reposition from a known-good absolute position instead of drifting.
pageBasePos := Map()
for pKey, pArr in pages {
    basePositions := []
    for ctrl in pArr {
        try {
            ctrl.GetPos(&cx, &cy)
            basePositions.Push([ctrl, cx, cy])
        }
    }
    pageBasePos[pKey] := basePositions
}
pageScrollY := Map()
for pKey, pArr in pages
    pageScrollY[pKey] := 0

PageContentBottom(key) {
    global pageBasePos
    maxBottom := 0
    for item in pageBasePos[key] {
        try {
            item[1].GetPos(, , , &ch)
            bottom := item[3] + ch
            if bottom > maxBottom
                maxBottom := bottom
        }
    }
    return maxBottom
}

ApplyPageScroll(key) {
    global pageBasePos, pageScrollY
    off := pageScrollY[key]
    for item in pageBasePos[key] {
        try item[1].Move(item[2], item[3] - off)
    }
}

OnMouseWheelScroll(wParam, lParam, msg, hwnd) {
    global pages, currentPage, pageScrollY, MyGui
    if !pages.Has(currentPage)
        return
    WinGetClientPos(, , , &winH, "ahk_id " MyGui.Hwnd)
    maxScroll := PageContentBottom(currentPage) - (winH - 12)
    if maxScroll < 0
        maxScroll := 0
    if maxScroll = 0
        return  ; this page already fits - nothing to scroll

    deltaNotches := (wParam >> 16) & 0xFFFF
    if deltaNotches > 0x7FFF
        deltaNotches -= 0x10000

    ScrollPageBy(deltaNotches > 0 ? -40 : 40)
}
OnMessage(0x20A, OnMouseWheelScroll)

; Shared by the mouse-wheel handler and the always-visible scroll buttons
; below, so every tab can be scrolled the same way even if a wheel event
; doesn't reach a particular control (e.g. while a dropdown has focus).
ScrollPageBy(amount) {
    global pages, currentPage, pageScrollY, MyGui
    if !pages.Has(currentPage)
        return
    if currentPage = "games"
        return  ; Games/Slap Battles never scrolls - it's sized to fit instead.
    WinGetClientPos(, , , &winH, "ahk_id " MyGui.Hwnd)
    maxScroll := PageContentBottom(currentPage) - (winH - 12)
    if maxScroll < 0
        maxScroll := 0
    newScroll := Max(0, Min(pageScrollY[currentPage] + amount, maxScroll))
    if newScroll = pageScrollY[currentPage]
        return
    pageScrollY[currentPage] := newScroll
    ApplyPageScroll(currentPage)
}

; Always-on-top scroll affordance (created last, after every tab's own
; controls, so it draws above them and is never part of any page's control
; list — it stays visible no matter which tab is showing). Visibility is
; toggled per-page in ShowPage/UpdateScrollArrows - only shown on pages
; that actually overflow the window.
btnScrollUp := MakeStyledButton(MyGui, 737, 118, 16, 22, "▲", (*) => ScrollPageBy(-60), "C34778", "81254F")
btnScrollDown := MakeStyledButton(MyGui, 737, 500, 16, 22, "▼", (*) => ScrollPageBy(60), "C34778", "81254F")

UpdateScrollArrows() {
    global pages, currentPage, btnScrollUp, btnScrollDown, MyGui
    needed := false
    if currentPage = "games" {
        ; Games/Slap Battles never shows the scroll arrows - the page is
        ; sized to always fit instead of needing to scroll.
        try btnScrollUp.Visible := false
        try btnScrollDown.Visible := false
        return
    }
    if pages.Has(currentPage) {
        ; Fails before the window is first shown (e.g. the initial
        ; ShowPage("dashboard") at startup, which runs before MyGui.Show());
        ; just skip the check then - it runs again on every real tab switch.
        try {
            WinGetClientPos(, , , &winH, "ahk_id " MyGui.Hwnd)
            needed := PageContentBottom(currentPage) > (winH - 12)
        }
    }
    try btnScrollUp.Visible := needed
    try btnScrollDown.Visible := needed
}

ShowPage(key) {
    global pages, navLabels, navButtons, currentPage, pageScrollY, accent, bg, fg, MyGui
    if !pages.Has(key)
        return
    for k, arr in pages {
        visible := (k = key)
        for ctrl in arr
            try ctrl.Opt(visible ? "-Hidden" : "+Hidden")
    }
    for k, btn in navButtons {
        btn.Text := (k = key ? "> " : "") . navLabels[k]
        try btn.Opt("Background" (k = key ? accent : bg) " c" fg)
    }
    currentPage := key
    pageScrollY[key] := 0
    ApplyPageScroll(key)
    if key = "autoclicker"
        UpdateModeUI()
    if key = "games"
        UpdateGamesUI()
    UpdateScrollArrows()
    try WinRedraw(MyGui.Hwnd)
}

ChooseDashboardImage() {
    global dashboardImagePath, dashPic, dashPicHint, dataFile
    chosen := FileSelect(1, , "Choose a dashboard picture", "Images (*.png; *.jpg; *.jpeg; *.gif; *.bmp)")
    if chosen = ""
        return
    dashboardImagePath := chosen
    dashPic.Value := chosen
    dashPicHint.Text := chosen
    IniWrite(chosen, dataFile, "Dashboard", "ImagePath")
}

; Start with no content page selected. Pages are laid out and shown only
; after the user clicks a sidebar item, which avoids the first-render clipping
; caused by hidden controls being created before their page is activated.
for k, arr in pages {
    for ctrl in arr
        try ctrl.Opt("+Hidden")
}
for k, btn in navButtons {
    btn.Text := navLabels[k]
    try btn.Opt("Background" bg " c" fg)
}
; Show the Dashboard on startup. Only the Dashboard is visible initially;
; Auto Clicker and its mode panels remain hidden until that page is opened.
ShowPage("dashboard")
; ================= Events =================
ddRepeat.OnEvent("Change", (*) => eCount.Enabled := (ddRepeat.Text = "Fixed Count"))
ddHotkey.OnEvent("Change", (*) => UpdateHotkey())
ddMode.OnEvent("Change", (*) => UpdateModeUI())
chkFischEnable.OnEvent("Click", (*) => ToggleFisch())

; ---------------- Mode helpers ----------------
KeyPressOptions() {
    keys := []
    loop 9
        keys.Push(String(A_Index))
    keys.Push("0")
    loop 26
        keys.Push(Chr(64 + A_Index))
    special := ["Space", "Enter", "Tab", "Escape", "Backspace", "Delete", "Insert"
        , "Home", "End", "PgUp", "PgDn", "Up", "Down", "Left", "Right"
        , "LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt", "LWin", "RWin"
        , "CapsLock", "AppsKey", "PrintScreen", "ScrollLock", "Pause", "NumLock"
        , "F1", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
        , "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9"
        , "NumpadDot", "NumpadAdd", "NumpadSub", "NumpadMult", "NumpadDiv", "NumpadEnter"
        , "-", "=", "[", "]", "\", "``", ";", "'", ",", ".", "/"]
    for k in special
        keys.Push(k)
    return keys
}

CurrentMode() {
    global ddMode
    t := ddMode.Text
    if InStr(t, "Window Focus")
        return "Window"
    if InStr(t, "Key Press")
        return "Key"
    return "Normal"
}

UpdateModeUI() {
    global ddMode, accent, sub
    global grpNormal, txtNormalHint1, txtNormalHint2, txtNormalHint3
    global grpTarget, txtWinLabel, ddWinList, btnRefresh, btnUseSelected, btnPickSpot, txtTarget, txtCoords
    global grpKey, txtKeyLabel, ddKeyPress, txtKeyHint1, txtKeyHint2, txtKeyHint3
    global ddButton, ddType, btnTest

    mode := CurrentMode()
    normalMode := (mode = "Normal")
    windowMode := (mode = "Window")
    keyMode    := (mode = "Key")

    for ctrl in [grpNormal, txtNormalHint1, txtNormalHint2, txtNormalHint3]
        ctrl.Visible := normalMode
    grpNormal.Opt(normalMode ? "c" accent : "c" sub)

    for ctrl in [grpTarget, txtWinLabel, ddWinList, btnRefresh, btnUseSelected, btnPickSpot, txtTarget, txtCoords]
        ctrl.Visible := windowMode
    grpTarget.Opt(windowMode ? "c" accent : "c" sub)

    for ctrl in [grpKey, txtKeyLabel, ddKeyPress, txtKeyHint1, txtKeyHint2, txtKeyHint3]
        ctrl.Visible := keyMode
    grpKey.Opt(keyMode ? "c" accent : "c" sub)

    ; Button/double-click type only apply to real mouse clicks
    ddButton.Enabled := !keyMode
    ddType.Enabled := !keyMode

    btnTest.Text := keyMode ? "Test Key Press Once" : "Test Click Once"
}
; Do not initialize the Auto Clicker mode panel at startup.
; It stays hidden until the Auto Clicker page is opened, where ShowPage() initializes it.
RefreshWindowList()

; ---------------- Window picker list ----------------
RefreshWindowList() {
    global winList, ddWinList
    winList := Map()
    items := []
    idx := 1
    for hwnd in WinGetList() {
        try t := WinGetTitle("ahk_id " hwnd)
        catch {
            continue
        }
        if (t = "" || t = "Macro AIO")
            continue
        winList[idx] := hwnd
        display := StrLen(t) > 40 ? SubStr(t, 1, 40) "..." : t
        items.Push(display)
        idx += 1
    }
    if items.Length = 0
        items.Push("(no windows found)")
    ddWinList.Delete()
    ddWinList.Add(items)
    ddWinList.Choose(1)
}

UseSelectedWindow() {
    global targetTopHwnd, targetTitle, targetHwnd, clickX, clickY, winList
    global ddWinList, txtTarget, txtCoords
    i := ddWinList.Value
    if !winList.Has(i) {
        MsgBox("Pick a valid window from the list first (hit Refresh if empty).", "Macro AIO", 48)
        return
    }
    targetTopHwnd := winList[i]
    targetTitle := WinGetTitle("ahk_id " targetTopHwnd)
    targetHwnd := 0
    clickX := 0, clickY := 0
    shortTitle := StrLen(targetTitle) > 32 ? SubStr(targetTitle, 1, 32) "..." : targetTitle
    txtTarget.Text := "Selected: " shortTitle
    txtCoords.Text := "Now click 'Set Spot' and press F3 over the exact spot."
}

; ---------------- Click-spot picking ----------------
BeginPickSpot() {
    global pickMode, targetTopHwnd
    if !targetTopHwnd {
        MsgBox("Select a window from the list first, then click 'Use Selected'.", "Macro AIO", 48)
        return
    }
    pickMode := true
    ToolTip("Hover the exact click-spot inside that window and press F3. Esc to cancel.")
    SetTimer(WatchPick, 50)
}

WatchPick() {
    global pickMode, targetHwnd, clickX, clickY, txtCoords
    if !pickMode
        return
    if GetKeyState("F3", "P") {
        MouseGetPos(&mx, &my)
        child := GetDeepestChildAtScreenPoint(mx, my)
        if child {
            targetHwnd := child
            pt := Buffer(8, 0)
            NumPut("int", mx, pt, 0)
            NumPut("int", my, pt, 4)
            DllCall("ScreenToClient", "ptr", child, "ptr", pt)
            clickX := NumGet(pt, 0, "int")
            clickY := NumGet(pt, 4, "int")
            txtCoords.Text := "Position set: x=" clickX ", y=" clickY " (locked)"
        }
        ToolTip()
        SetTimer(WatchPick, 0)
        pickMode := false
    } else if GetKeyState("Escape", "P") {
        ToolTip()
        SetTimer(WatchPick, 0)
        pickMode := false
    }
}

GetDeepestChildAtScreenPoint(sx, sy) {
    hwnd := DllCall("WindowFromPoint", "int64", (sy << 32) | (sx & 0xFFFFFFFF), "ptr")
    if !hwnd
        return 0
    loop {
        pt := Buffer(8, 0)
        NumPut("int", sx, pt, 0)
        NumPut("int", sy, pt, 4)
        DllCall("ScreenToClient", "ptr", hwnd, "ptr", pt)
        cx := NumGet(pt, 0, "int"), cy := NumGet(pt, 4, "int")
        child := DllCall("ChildWindowFromPointEx", "ptr", hwnd, "int64", (cy << 32) | (cx & 0xFFFFFFFF), "uint", 1, "ptr")
        if !child || child = hwnd
            break
        hwnd := child
    }
    return hwnd
}

; ---------------- Hotkey management ----------------
; Note: the Hotkey control fires "Change" on every in-progress keystroke
; while recording a combo (e.g. once for just Ctrl, again once the full
; combo is pressed) - not just once at the end. This only acts on a real,
; different, bindable key, and never writes back into the control itself
; (doing that mid-recording cancels the recording).
UpdateHotkey() {
    global toggleKey, ddHotkey, btnStart, btnStop

    newKey := ddHotkey.Value
    if newKey = toggleKey
        return  ; not an actual change (duplicate/partial Change event) - ignore it

    if newKey = "" {
        try Hotkey(toggleKey, ToggleClicking, "Off")
        toggleKey := ""
        btnStart.Text := "Start (no hotkey)"
        btnStop.Text := "Stop (no hotkey)"
        return
    }

    try {
        ; Confirm the new key actually works BEFORE giving up the old one.
        Hotkey(newKey, ToggleClicking, "On")
        if toggleKey != ""
            try Hotkey(toggleKey, ToggleClicking, "Off")
        toggleKey := newKey
        btnStart.Text := "Start (" toggleKey ")"
        btnStop.Text := "Stop (" toggleKey ")"
    } catch {
        ; Not bindable yet (mid-recording a combo) - leave the old binding
        ; and the control alone; it'll settle on the next keypress.
    }
}

ToggleClicking(*) {
    global clicking
    if clicking
        StopClicking()
    else
        StartClicking()
}

; ---------------- Start / Stop ----------------
StartClicking() {
    global clicking, cpsWindowStart, cpsWindowCount, targetHwnd, txtStatus, green, chkHighSpeed
    if CurrentMode() = "Window" && !targetHwnd {
        MsgBox("Select a window AND set a click spot first.", "Macro AIO", 48)
        return
    }
    if clicking
        return
    clicking := true
    cpsWindowStart := A_TickCount
    cpsWindowCount := 0
    txtStatus.Text := "RUNNING"
    txtStatus.Opt("c" green)
    if chkHighSpeed.Value
        StartHighSpeed()
    else
        SetTimer(DoClick, -1)
}

StopClicking() {
    global clicking, txtStatus, red, txtLiveCps
    clicking := false
    SetTimer(DoClick, 0)
    SetTimer(HighSpeedTick, 0)
    txtStatus.Text := "STOPPED"
    txtStatus.Opt("c" red)
    txtLiveCps.Text := "0.0"
}

TestClick() {
    global ddButton, ddKeyPress, targetHwnd, clickX, clickY
    mode := CurrentMode()
    btn := ddButton.Text
    if mode = "Window" {
        if !targetHwnd {
            MsgBox("Select a window and set a click spot first.", "Macro AIO", 48)
            return
        }
        SendBackgroundClick(targetHwnd, clickX, clickY, btn)
        ToolTip("Sent 1 test click.")
        SetTimer(() => ToolTip(), -1000)
    } else if mode = "Key" {
        key := ddKeyPress.Text
        Send("{" key " down}")
        Send("{" key " up}")
        ToolTip("Sent 1 test key press: " key)
        SetTimer(() => ToolTip(), -1000)
    } else {
        Click(btn)
    }
}

; ---------------- Click logic ----------------
DoClick() {
    global clicking, sessionClicks, lifetimeClicks, targetHwnd, targetTopHwnd
    global clickX, clickY, cpsWindowStart, cpsWindowCount, sessionPeakCps
    global chkFailsafe, eHours, eMins, eSecs, eMs, ddButton, ddType, ddKeyPress
    global ddRepeat, eCount, txtLiveCps, txtSessionClicks, currentPage

    if !clicking
        return

    if chkFailsafe.Value {
        MouseGetPos(&fmx, &fmy)
        if fmy >= A_ScreenHeight - 2 {
            StopClicking()
            ToolTip("Failsafe triggered - cursor hit bottom of screen.")
            SetTimer(() => ToolTip(), -2000)
            return
        }
    }

    h := Integer(eHours.Text = "" ? 0 : eHours.Text)
    m := Integer(eMins.Text = "" ? 0 : eMins.Text)
    s := Integer(eSecs.Text = "" ? 0 : eSecs.Text)
    ms := Integer(eMs.Text = "" ? 0 : eMs.Text)
    interval := ms + (s * 1000) + (m * 60000) + (h * 3600000)
    if interval < 1
        interval := 1

    mode := CurrentMode()
    btn := ddButton.Text
    doubleClick := ddType.Text = "Double"

    if mode = "Window" {
        if !WinExist("ahk_id " targetTopHwnd) {
            StopClicking()
            ToolTip("Target window closed - clicker stopped.")
            SetTimer(() => ToolTip(), -2000)
            return
        }
        SendBackgroundClick(targetHwnd, clickX, clickY, btn)
        if CurrentPageIsCpsTarget(targetHwnd)
            NotifyCpsAutoClick(1)
        if doubleClick {
            SendBackgroundClick(targetHwnd, clickX, clickY, btn)
            if CurrentPageIsCpsTarget(targetHwnd)
                NotifyCpsAutoClick(1)
        }
    } else if mode = "Key" {
        key := ddKeyPress.Text
        Send("{" key " down}")
        Send("{" key " up}")
        if doubleClick {
            Send("{" key " down}")
            Send("{" key " up}")
        }
    } else {
        clickCount := doubleClick ? 2 : 1
        Click(btn, clickCount)
        ; Feed our own synthetic clicks directly into the CPS engine.
        ; AHK-generated Click events do not reliably pass through the global
        ; physical LButton hotkey, so relying on that hook alone misses the
        ; autoclicker's clicks.
        if currentPage = "cpstest"
            NotifyCpsAutoClick(clickCount)
    }

    sessionClicks += 1
    lifetimeClicks += 1
    cpsWindowCount += 1
    txtSessionClicks.Text := sessionClicks

    elapsed := A_TickCount - cpsWindowStart
    if elapsed >= 400 {
        actualCps := Round(cpsWindowCount / (elapsed / 1000), 1)
        txtLiveCps.Text := actualCps
        if actualCps > sessionPeakCps
            sessionPeakCps := actualCps
        cpsWindowStart := A_TickCount
        cpsWindowCount := 0
    }

    if (ddRepeat.Text = "Fixed Count") {
        target := Integer(eCount.Text = "" ? 0 : eCount.Text)
        if sessionClicks >= target {
            StopClicking()
            return
        }
    }

    if clicking
        SetTimer(DoClick, -interval)
}

SendBackgroundClick(hwnd, x, y, button) {
    lParam := (y << 16) | (x & 0xFFFF)
    if (button = "Left") {
        downMsg := 0x201, upMsg := 0x202, wp := 1
    } else if (button = "Right") {
        downMsg := 0x204, upMsg := 0x205, wp := 2
    } else {
        downMsg := 0x207, upMsg := 0x208, wp := 0x10
    }
    PostMessage(0x200, 0, lParam, , "ahk_id " hwnd)
    PostMessage(downMsg, wp, lParam, , "ahk_id " hwnd)
    PostMessage(upMsg, 0, lParam, , "ahk_id " hwnd)
}

; ---------------- High Speed Mode ----------------
; Why the normal clicker stalls around 60-70 CPS: it fires ONE click per
; SetTimer callback, Windows timers only tick about every 15.6ms (~64 a
; second), and every click also does GUI work. High Speed Mode decouples the
; click rate from the timer rate: a short tick (every few ms) works out how
; many clicks are "owed" since the last tick using the high-resolution
; counter, then sends them all in ONE batched call. Ticks stay tiny, so the
; rest of the macro (Bob Farm, Fisch, recorder, GUI) keeps running smoothly.
; Everything is wrapped in try/catch so a problem stops the clicker quietly
; with a tooltip instead of throwing an AHK error dialog.

StartHighSpeed() {
    global hsFreq, hsLast, hsCarry, hsRunClicks
    freq := 0, startCount := 0
    try {
        DllCall("QueryPerformanceFrequency", "Int64*", &freq)
        DllCall("QueryPerformanceCounter", "Int64*", &startCount)
    } catch {
        freq := 0
    }
    if freq <= 0 {
        ; No high-res counter available - fall back to the normal clicker.
        SetTimer(DoClick, -1)
        return
    }
    hsFreq := freq
    hsLast := startCount
    hsCarry := 0.0
    hsRunClicks := 0
    SetTimer(HighSpeedTick, 5)
}

; Reads the Target CPS box without ever throwing on blank/garbage text.
HsReadCps() {
    global eHsCps
    t := Trim(eHsCps.Text)
    if !IsNumber(t)
        return 100
    return Min(Max(t + 0, 1), 10000)
}

HsInt(text, fallback := 0) {
    t := Trim(text)
    return IsInteger(t) ? Integer(t) : fallback
}

HighSpeedTick() {
    global clicking, hsFreq, hsLast, hsCarry, hsRunClicks
    global sessionClicks, lifetimeClicks, cpsWindowStart, cpsWindowCount, sessionPeakCps
    global chkFailsafe, ddButton, ddType, ddKeyPress, ddRepeat, eCount
    global targetHwnd, targetTopHwnd, clickX, clickY
    global txtSessionClicks, txtLiveCps, currentPage

    if !clicking {
        SetTimer(HighSpeedTick, 0)
        return
    }

    try {
        ; Same bottom-of-screen failsafe as the normal clicker.
        if chkFailsafe.Value {
            MouseGetPos(&fmx, &fmy)
            if fmy >= A_ScreenHeight - 2 {
                StopClicking()
                ToolTip("Failsafe triggered - cursor hit bottom of screen.")
                SetTimer(() => ToolTip(), -2000)
                return
            }
        }

        ; How many clicks are owed since the last tick?
        nowCount := 0
        DllCall("QueryPerformanceCounter", "Int64*", &nowCount)
        dt := (nowCount - hsLast) / hsFreq
        hsLast := nowCount
        if dt <= 0
            return
        if dt > 0.1
            dt := 0.02   ; the script stalled (window drag etc.) - don't dump a huge catch-up burst
        hsCarry += dt * HsReadCps()
        n := Floor(hsCarry)
        if n < 1
            return
        hsCarry -= n

        mode := CurrentMode()
        mult := (ddType.Text = "Double") ? 2 : 1

        ; Per-tick safety caps so one batch can never flood the input queue
        ; or the target window's message queue (Window mode is the touchiest).
        maxRaw := (mode = "Window") ? 25 : (mode = "Key") ? 60 : 300
        capActions := Max(1, maxRaw // mult)
        if n > capActions
            n := capActions   ; can't keep up this tick - drop the excess instead of building a backlog

        fixedCount := (ddRepeat.Text = "Fixed Count")
        target := 0
        if fixedCount {
            target := HsInt(eCount.Text, 0)
            if hsRunClicks >= target {
                StopClicking()
                return
            }
            if n > target - hsRunClicks
                n := target - hsRunClicks
        }

        ; Make sure no artificial per-click delay applies in this timer thread.
        SetMouseDelay(-1)
        SetKeyDelay(-1, -1)

        btn := ddButton.Text
        raw := n * mult

        if mode = "Window" {
            if !WinExist("ahk_id " targetTopHwnd) {
                StopClicking()
                ToolTip("Target window closed - clicker stopped.")
                SetTimer(() => ToolTip(), -2000)
                return
            }
            sent := 0
            loop raw {
                try {
                    SendBackgroundClick(targetHwnd, clickX, clickY, btn)
                } catch {
                    break   ; target's queue is full or the window vanished - skip the rest this tick
                }
                sent += 1
            }
            if sent = 0
                return
            raw := sent
            n := Ceil(sent / mult)
            if CurrentPageIsCpsTarget(targetHwnd)
                NotifyCpsAutoClick(raw)
        } else if mode = "Key" {
            key := ddKeyPress.Text
            one := "{" key " down}{" key " up}"
            seq := ""
            loop raw
                seq .= one
            Send(seq)
        } else {
            Click(btn, raw)
            if currentPage = "cpstest"
                NotifyCpsAutoClick(raw)
        }

        hsRunClicks += n
        sessionClicks += n
        lifetimeClicks += n
        cpsWindowCount += n

        ; GUI text is only refreshed a few times a second - updating it on
        ; every batch is exactly the kind of overhead that causes lag.
        nowTick := A_TickCount
        elapsed := nowTick - cpsWindowStart
        if elapsed >= 250 {
            actualCps := Round(cpsWindowCount / (elapsed / 1000), 1)
            txtLiveCps.Text := actualCps
            txtSessionClicks.Text := sessionClicks
            if actualCps > sessionPeakCps
                sessionPeakCps := actualCps
            cpsWindowStart := nowTick
            cpsWindowCount := 0
        }

        if fixedCount && hsRunClicks >= target
            StopClicking()
    } catch as err {
        HighSpeedFail(err)
    }
}

; Any unexpected problem lands here: stop quietly, never show an error dialog.
HighSpeedFail(err) {
    try {
        StopClicking()
    } catch {
    }
    try {
        msg := ""
        try {
            msg := err.Message
        } catch {
            msg := "unknown error"
        }
        ToolTip("High Speed Mode stopped: " msg)
        SetTimer(() => ToolTip(), -3000)
    } catch {
    }
}

; ---------------- CPS Test ----------------
CurrentPageIsCpsTarget(hwnd) {
    global currentPage, btnCpsBox
    if currentPage != "cpstest" || !btnCpsBox.Enabled
        return false
    return hwnd = btnCpsBox.Hwnd
}

NotifyCpsAutoClick(count := 1) {
    global currentPage, cpsTestRunning, cpsTestClicks, cpsTestEndTick, btnCpsBox, txtCpsCount
    if currentPage != "cpstest" || !btnCpsBox.Enabled
        return

    now := A_TickCount
    if !cpsTestRunning {
        ; The first synthetic click starts the test and is itself a counted
        ; click, matching the physical-click path.
        CpsTestBegin()
    }

    if !cpsTestRunning
        return

    if now >= cpsTestEndTick {
        CpsTestTick()
        return
    }

    cpsTestClicks += count
    txtCpsCount.Text := "Clicks: " cpsTestClicks
}

CpsTestClick() {
    ; Fallback for the GUI control's Click notification. The actual CPS
    ; counting is handled by the global physical-mouse hook below so rapid
    ; clicks are not lost by GUI command/event throttling.
    global cpsTestRunning, btnCpsBox
    if !btnCpsBox.Enabled
        return
    if !cpsTestRunning
        CpsTestBegin()
}

CpsTestBegin() {
    global cpsTestRunning, cpsTestClicks, cpsTestEndTick, ddCpsDuration
    global btnCpsBox, txtCpsResult, txtCpsTimer, txtCpsCount
    durText := ddCpsDuration.Text
    durSec := Integer(StrSplit(durText, " ")[1])
    cpsTestRunning := true
    cpsTestClicks := 0
    cpsTestEndTick := A_TickCount + (durSec * 1000)
    btnCpsBox.Text := "GO! Keep clicking..."
    txtCpsResult.Text := "Testing..."
    txtCpsTimer.Text := "Time left: " durSec ".0s"
    txtCpsCount.Text := "Clicks: 0"
    SetTimer(CpsTestTick, 25)
}

CpsTestRawMouseDown(*) {
    global currentPage, cpsTestRunning, cpsTestClicks, cpsTestEndTick, btnCpsBox, txtCpsCount

    ; Only count physical left-button presses that actually land on the big
    ; CPS test surface. WindowFromPoint is much lighter than asking the GUI
    ; for positions on every click, which helps at high CPS.
    if currentPage != "cpstest" || !btnCpsBox.Enabled
        return

    MouseGetPos(&mx, &my)
    hitHwnd := DllCall("WindowFromPoint", "int64", (my << 32) | (mx & 0xFFFFFFFF), "ptr")
    if hitHwnd != btnCpsBox.Hwnd
        return

    now := A_TickCount
    if !cpsTestRunning {
        CpsTestBegin()
        return
    }

    ; Exclude a click that lands after the test window has expired but before
    ; the display timer gets its next 25 ms tick.
    if now >= cpsTestEndTick {
        CpsTestTick()
        return
    }

    cpsTestClicks += 1
    txtCpsCount.Text := "Clicks: " cpsTestClicks
}

CpsTestTick() {
    global cpsTestRunning, cpsTestClicks, cpsTestEndTick
    global ddCpsDuration, txtCpsResult, txtCpsTimer
    remaining := cpsTestEndTick - A_TickCount
    if remaining <= 0 {
        cpsTestRunning := false
        SetTimer(CpsTestTick, 0)
        durText := ddCpsDuration.Text
        durSec := Integer(StrSplit(durText, " ")[1])
        finalCps := Round(cpsTestClicks / durSec, 2)
        txtCpsResult.Text := finalCps " CPS  (" cpsTestClicks " clicks / " durSec "s)"
        txtCpsTimer.Text := "Time left: -"
        StartCpsCooldown()
        return
    }
    txtCpsTimer.Text := "Time left: " Round(remaining / 1000, 1) "s"
}

StartCpsCooldown() {
    global cpsCooldownEndTick, btnCpsBox
    cpsCooldownEndTick := A_TickCount + 5000
    btnCpsBox.Enabled := false
    SetTimer(CpsCooldownTick, 50)
}

CpsCooldownTick() {
    global cpsCooldownEndTick, btnCpsBox
    remaining := cpsCooldownEndTick - A_TickCount
    if remaining <= 0 {
        SetTimer(CpsCooldownTick, 0)
        btnCpsBox.Text := "Click here to start"
        btnCpsBox.Enabled := true
        return
    }
    btnCpsBox.Text := "Cooldown: " Round(remaining / 1000, 1) "s"
}

; ---------------- Typing Test ----------------
typingRunning  := false
typingText     := ""
typingIndex    := 1
typingDelayMs  := 200
typingToggleKey := ""

ToggleTypingTest(*) {
    global typingRunning
    if typingRunning
        StopTypingTest()
    else
        StartTypingTest()
}

; Fired only by clicking "Save Keybind" (a deliberate action), not on every
; live keystroke in the box - a Hotkey control fires its Change event on
; every in-progress key while recording a combo, and reacting to those
; automatically (and writing back into the box to "revert" a bad one) is
; what was cancelling the recording and leaving it stuck on "No keybind
; set." Recording a combo in the box first, then explicitly clicking Save,
; sidesteps that entirely.
UpdateTypingTestHotkey(*) {
    global typingToggleKey, ttHotkey, ttStatus

    newKey := ttHotkey.Value
    if newKey = "" {
        try Hotkey(typingToggleKey, ToggleTypingTest, "Off")
        typingToggleKey := ""
        ttStatus.Text := "No keybind set — record one above, then click Save Keybind."
        return
    }
    if newKey = typingToggleKey {
        ttStatus.Text := "Idle. Toggle key: " typingToggleKey " (already saved)."
        return
    }

    try {
        ; Confirm the new key actually works BEFORE giving up the old one.
        Hotkey(newKey, ToggleTypingTest, "On")
        if typingToggleKey != ""
            try Hotkey(typingToggleKey, ToggleTypingTest, "Off")
        typingToggleKey := newKey
        ttStatus.Text := "Saved! Idle. Toggle key: " typingToggleKey
    } catch {
        ttStatus.Text := "Couldn't bind that key/combo — try a different one."
    }
}

; Human Mode's "Typos" checkbox only makes sense once Human Mode itself is
; on, so it's kept disabled (and turned off) whenever Human Mode is off.
UpdateHumanModeUI() {
    global chkHumanMode, chkTypos
    chkTypos.Enabled := chkHumanMode.Value
    if !chkHumanMode.Value
        chkTypos.Value := 0
}

StartTypingTest() {
    global ttPhrase, ttWPM, ttStatus, typingRunning, typingText, typingIndex, typingDelayMs

    phrase := ttPhrase.Text
    if phrase = "" {
        ttStatus.Text := "Type a phrase first."
        return
    }
    wpm := Integer(ttWPM.Text = "" ? 60 : ttWPM.Text)
    if wpm < 1
        wpm := 1

    ; Standard WPM convention: 1 "word" = 5 characters (including spaces).
    typingDelayMs := Round(60000 / (wpm * 5))
    typingText := phrase
    typingIndex := 1
    typingRunning := true
    ttStatus.Text := "Typing at " wpm " WPM..."
    SetTimer(TypingTestTick, -typingDelayMs)
}

StopTypingTest() {
    global typingRunning, ttStatus
    wasRunning := typingRunning
    typingRunning := false
    SetTimer(TypingTestTick, 0)
    if wasRunning
        ttStatus.Text := "Stopped."
}

; Picks a random letter other than excludeChar, matching its case if it's
; a letter itself (so typo-ing "T" gives a wrong letter like "R", not "r").
RandomWrongLetter(excludeChar) {
    letters := "abcdefghijklmnopqrstuvwxyz"
    isUpper := excludeChar == StrUpper(excludeChar) && excludeChar != StrLower(excludeChar)
    loop {
        pick := SubStr(letters, Random(1, 26), 1)
        if isUpper
            pick := StrUpper(pick)
        if pick != excludeChar
            return pick
    }
}

TypingTestTick() {
    global typingRunning, typingText, typingIndex, typingDelayMs, ttStatus, chkHumanMode, chkTypos

    if !typingRunning
        return
    if typingIndex > StrLen(typingText) {
        typingRunning := false
        ttStatus.Text := "Done."
        return
    }

    char := SubStr(typingText, typingIndex, 1)
    humanMode := chkHumanMode.Value
    nextDelay := typingDelayMs

    if humanMode {
        ; Fluctuate each keystroke's timing by roughly +/-35% so the pace
        ; doesn't look like a metronome.
        nextDelay := Round(typingDelayMs * (Random(65, 135) / 100))
        if nextDelay < 1
            nextDelay := 1
    }

    ; Typos only ever apply to actual letters, and never to the space bar.
    isLetter := char != "" && RegExMatch(char, "^[A-Za-z]$")
    if humanMode && chkTypos.Value && isLetter && char != " " && Random(1, 100) <= 10 {
        wrongChar := RandomWrongLetter(char)
        SendText(wrongChar)
        Sleep(Random(70, 160))
        Send("{Backspace}")
        Sleep(Random(50, 130))
        SendText(char)
    } else {
        SendText(char)
    }

    typingIndex += 1
    if typingRunning
        SetTimer(TypingTestTick, -nextDelay)
}

; ---------------- Global kill switch ----------------
KillSwitch(*) {
    global clicking, recording, playing, playbackPaused, visionWatching, btnWatch, chkFischEnable, fischShaking, txtFischStatus
    global chkFarmEnable, txtFarmStatus, defaultDetectors
    for d in defaultDetectors {
        if d["enabled"] {
            d["enabled"] := false
            try d["chk"].Value := 0
        }
    }
    if clicking
        StopClicking()
    if recording
        StopRecording()
    if playing || playbackPaused
        StopPlayback()
    if visionWatching {
        visionWatching := false
        SetTimer(WatchTick, 0)
        btnWatch.Text := "Start Watching"
    }
    if chkFischEnable.Value {
        chkFischEnable.Value := 0
        StopFischShaking()
        txtFischStatus.Text := "Disabled (kill switch)."
    }
    if chkFarmEnable.Value {
        chkFarmEnable.Value := 0
        StopBobFarm()
        txtFarmStatus.Text := "Disabled (kill switch)."
    }
    if typingRunning {
        StopTypingTest()
        ttStatus.Text := "Stopped (kill switch)."
    }
    if btdRunning
        StopBtd()
    ; Release every modifier/mouse-button that might be stuck down from a bugged macro
    Send("{Blind}{LShift up}{RShift up}{LCtrl up}{RCtrl up}{LAlt up}{RAlt up}{LWin up}{RWin up}")
    Click("Left", , , "U")
    Click("Right", , , "U")
    Click("Middle", , , "U")
    ToolTip("⛔ KILL SWITCH — everything stopped, keys released")
    SetTimer(() => ToolTip(), -1500)
}

; ---------------- Recorder: input hooks ----------------
BuildRecordableKeyList() {
    keys := []
    loop 26
        keys.Push(Chr(96 + A_Index))
    loop 10
        keys.Push(String(A_Index - 1))
    extra := ["Space", "Enter", "Tab", "Escape", "Backspace", "Delete", "Insert", "Home", "End", "PgUp", "PgDn"
        , "Up", "Down", "Left", "Right", "LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt", "LWin", "RWin"
        , "CapsLock", "AppsKey", "PrintScreen", "ScrollLock", "Pause", "NumLock"
        , "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9"
        , "NumpadDot", "NumpadAdd", "NumpadSub", "NumpadMult", "NumpadDiv", "NumpadEnter"
        , "F1", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
        , "-", "=", "[", "]", "\", "``", ";", "'", ",", ".", "/"
        , "LButton", "RButton", "MButton", "WheelUp", "WheelDown"]
    for e in extra
        keys.Push(e)
    filtered := []
    for k in keys {
        if (k != "F2" && k != "F4")
            filtered.Push(k)
    }
    return filtered
}

RegisterRecordingHooks() {
    global recKeyList
    for k in recKeyList {
        ; LButton has a permanent shared hook below so CPS testing and
        ; recording can both observe every physical left-button press.
        if k = "LButton"
            continue
        try Hotkey("~" k, RecordInputEvent, "On")
        try Hotkey("~" k " Up", RecordInputEvent, "On")
    }
}

UnregisterRecordingHooks() {
    global recKeyList
    for k in recKeyList {
        if k = "LButton"
            continue
        try Hotkey("~" k, RecordInputEvent, "Off")
        try Hotkey("~" k " Up", RecordInputEvent, "Off")
    }
}

; Permanent pass-through hooks for left mouse down/up. These intentionally
; remain installed so the CPS test can count raw physical clicks without
; conflicting with the recorder's dynamically registered key hooks.
GlobalLButtonDown(*) {
    global recording
    CpsTestRawMouseDown()
    if recording
        RecordInputEvent()
}

GlobalLButtonUp(*) {
    global recording
    if recording
        RecordInputEvent()
}

RecordInputEvent(*) {
    global recording, recordStartTick, recordedEvents
    if !recording
        return
    raw := A_ThisHotkey
    isUp := InStr(raw, " Up") > 0
    name := StrReplace(StrReplace(raw, "~", ""), " Up", "")
    t := A_TickCount - recordStartTick
    if (name = "LButton" || name = "RButton" || name = "MButton") {
        MouseGetPos(&mx, &my)
        btn := name = "LButton" ? "Left" : (name = "RButton" ? "Right" : "Middle")
        recordedEvents.Push(Map("t", t, "type", isUp ? "mouseup" : "mousedown", "btn", btn, "x", mx, "y", my))
    } else if (name = "WheelUp" || name = "WheelDown") {
        recordedEvents.Push(Map("t", t, "type", "wheel", "dir", name = "WheelUp" ? "Up" : "Down"))
    } else {
        recordedEvents.Push(Map("t", t, "type", isUp ? "keyup" : "keydown", "key", name))
    }
}

PollMouseMove() {
    global recording, recordStartTick, recordedEvents, lastMoveX, lastMoveY, chkRecordMoves
    if !recording || !chkRecordMoves.Value
        return
    MouseGetPos(&mx, &my)
    if (mx != lastMoveX || my != lastMoveY) {
        lastMoveX := mx, lastMoveY := my
        t := A_TickCount - recordStartTick
        recordedEvents.Push(Map("t", t, "type", "move", "x", mx, "y", my))
    }
}

; ---------------- Recorder: start/stop ----------------
StartRecording() {
    global recording, clicking, playing, playbackPaused, recordStartTick, recordedEvents, lastMoveX, lastMoveY
    global macroStatusText, txtRecFile, chkRecordMoves
    if clicking || playing || playbackPaused {
        MsgBox("Stop the clicker/playback before recording.", "Macro AIO", 48)
        return
    }
    if recording
        return
    recordedEvents := []
    recording := true
    recordStartTick := A_TickCount
    MouseGetPos(&lastMoveX, &lastMoveY)
    if chkRecordMoves.Value
        recordedEvents.Push(Map("t", 0, "type", "move", "x", lastMoveX, "y", lastMoveY))
    RegisterRecordingHooks()
    SetTimer(PollMouseMove, 15)
    macroStatusText.Text := "Recording — capturing input"
    txtRecFile.Text := "Recording in progress..."
}

StopRecording() {
    global recording, macroStatusText
    if !recording
        return
    recording := false
    SetTimer(PollMouseMove, 0)
    UnregisterRecordingHooks()
    macroStatusText.Text := "Idle — recording ready"
    UpdateRecorderUI()
}

ToggleRecording(*) {
    global recording
    if recording
        StopRecording()
    else
        StartRecording()
}

; ---------------- Playback ----------------
StartPlayback() {
    global playing, recording, clicking, playbackPaused, recordedEvents, playbackIndex, playbackStartTick
    global playbackRepeatsTotal, playbackRepeatsDone, playbackPauseStartTick, ddPlayRepeat, macroStatusText, macroSpeedText, eSpeed
    if recording || clicking {
        MsgBox("Stop recording/clicking before playing back.", "Macro AIO", 48)
        return
    }
    if recordedEvents.Length = 0 {
        MsgBox("No recording to play. Record something first (F2).", "Macro AIO", 48)
        return
    }
    if playing
        return
    playing := true
    playbackPaused := false
    playbackPauseStartTick := 0
    playbackIndex := 1
    playbackStartTick := A_TickCount
    playbackRepeatsDone := 0
    repText := ddPlayRepeat.Text
    if InStr(repText, "Loop")
        playbackRepeatsTotal := -1
    else if InStr(repText, "Once")
        playbackRepeatsTotal := 1
    else
        playbackRepeatsTotal := Integer(StrReplace(StrSplit(repText, " ")[2], "x", ""))
    macroStatusText.Text := "Playing macro"
    macroSpeedText.Text := Integer(eSpeed.Text = "" ? 100 : eSpeed.Text) "%"
    SetTimer(PlaybackTick, -1)
}

StopPlayback() {
    global playing, playbackPaused, playbackPauseStartTick, macroStatusText, macroSpeedText
    if !playing && !playbackPaused
        return
    playing := false
    playbackPaused := false
    playbackPauseStartTick := 0
    SetTimer(PlaybackTick, 0)
    macroStatusText.Text := "Idle — ready"
    macroSpeedText.Text := "100%"
}

TogglePlaybackPause(*) {
    global playing, playbackPaused, playbackPauseStartTick, playbackStartTick, macroStatusText
    if playing {
        playing := false
        playbackPaused := true
        playbackPauseStartTick := A_TickCount
        SetTimer(PlaybackTick, 0)
        macroStatusText.Text := "Playback paused"
        return
    }
    if playbackPaused {
        playbackStartTick += A_TickCount - playbackPauseStartTick
        playbackPauseStartTick := 0
        playbackPaused := false
        playing := true
        macroStatusText.Text := "Playing macro"
        SetTimer(PlaybackTick, -1)
    }
}

StopMacroActivity(*) {
    global recording, playing, playbackPaused
    if recording
        StopRecording()
    if playing || playbackPaused
        StopPlayback()
}

TogglePlayback(*) {
    global playing, playbackPaused
    if playbackPaused {
        TogglePlaybackPause()
        return
    }
    if playing
        StopPlayback()
    else
        StartPlayback()
}

; Fired only by clicking "Save Keybind" (a deliberate action), not on every
; live keystroke in the box - a Hotkey control fires its Change event on
; every in-progress key while recording a combo, and reacting to that
; automatically is what caused the earlier "save keybind" feature to be
; unreliable. Recording a combo in the box first, then explicitly clicking
; Save, sidesteps that. The key is also written to the data ini so it's
; remembered the next time the app is opened, not just for this run.
UpdatePlaybackHotkey(*) {
    global playbackToggleKey, ddPlaybackHotkey, txtPlaybackKeyStatus, dataFile

    newKey := ddPlaybackHotkey.Value
    if newKey = "" {
        try Hotkey(playbackToggleKey, TogglePlayback, "Off")
        playbackToggleKey := ""
        txtPlaybackKeyStatus.Text := "No keybind set — record one, then click Save Keybind."
        IniWrite("", dataFile, "Hotkeys", "PlaybackKey")
        return
    }
    if newKey = playbackToggleKey {
        txtPlaybackKeyStatus.Text := "Toggle key: " playbackToggleKey " (already saved)."
        return
    }

    try {
        ; Confirm the new key actually works BEFORE giving up the old one.
        Hotkey(newKey, TogglePlayback, "On")
        if playbackToggleKey != ""
            try Hotkey(playbackToggleKey, TogglePlayback, "Off")
        playbackToggleKey := newKey
        IniWrite(playbackToggleKey, dataFile, "Hotkeys", "PlaybackKey")
        txtPlaybackKeyStatus.Text := "Saved! Toggle key: " playbackToggleKey
    } catch {
        txtPlaybackKeyStatus.Text := "Couldn't bind that key/combo — try a different one."
    }
}

PlaybackTick() {
    global playing, playbackPaused, recordedEvents, playbackIndex, playbackStartTick
    global playbackRepeatsTotal, playbackRepeatsDone, eSpeed, chkFailsafe, macroStatusText

    if !playing || playbackPaused
        return

    if chkFailsafe.Value {
        MouseGetPos(&fmx, &fmy)
        if fmy >= A_ScreenHeight - 2 {
            StopPlayback()
            ToolTip("Failsafe triggered - playback stopped.")
            SetTimer(() => ToolTip(), -2000)
            return
        }
    }

    if playbackIndex > recordedEvents.Length {
        playbackRepeatsDone += 1
        if playbackRepeatsTotal = -1 || playbackRepeatsDone < playbackRepeatsTotal {
            playbackIndex := 1
            playbackStartTick := A_TickCount
            SetTimer(PlaybackTick, -1)
            return
        } else {
            playing := false
            macroStatusText.Text := "Idle — playback complete"
            return
        }
    }

    speedPct := Integer(eSpeed.Text = "" ? 100 : eSpeed.Text)
    if speedPct < 1
        speedPct := 100
    speedFactor := speedPct / 100

    ev := recordedEvents[playbackIndex]
    targetElapsed := ev["t"] / speedFactor
    actualElapsed := A_TickCount - playbackStartTick
    wait := targetElapsed - actualElapsed
    if wait > 2 {
        SetTimer(PlaybackTick, -Min(wait, 1000))
        return
    }

    ExecutePlaybackEvent(ev)
    playbackIndex += 1
    SetTimer(PlaybackTick, -1)
}

ExecutePlaybackEvent(ev) {
    switch ev["type"] {
        case "move":
            MouseMove(ev["x"], ev["y"], 0)
        case "mousedown":
            Click(ev["x"], ev["y"], ev["btn"], , , "D")
        case "mouseup":
            Click(ev["x"], ev["y"], ev["btn"], , , "U")
        case "keydown":
            try Send("{" ev["key"] " down}")
        case "keyup":
            try Send("{" ev["key"] " up}")
        case "wheel":
            try Send(ev["dir"] = "Up" ? "{WheelUp}" : "{WheelDown}")
    }
}

; ---------------- Recorder: save / load / clear ----------------
EventsToText(events) {
    lines := ""
    for ev in events {
        switch ev["type"] {
            case "move":
                lines .= "MOVE|" ev["t"] "|" ev["x"] "|" ev["y"] "`n"
            case "keydown":
                lines .= "KD|" ev["t"] "|" ev["key"] "`n"
            case "keyup":
                lines .= "KU|" ev["t"] "|" ev["key"] "`n"
            case "mousedown":
                lines .= "MD|" ev["t"] "|" ev["btn"] "|" ev["x"] "|" ev["y"] "`n"
            case "mouseup":
                lines .= "MU|" ev["t"] "|" ev["btn"] "|" ev["x"] "|" ev["y"] "`n"
            case "wheel":
                lines .= "WH|" ev["t"] "|" ev["dir"] "`n"
        }
    }
    return lines
}

TextToEvents(content) {
    newEvents := []
    loop parse, content, "`n", "`r" {
        if A_LoopField = ""
            continue
        parts := StrSplit(A_LoopField, "|")
        type := parts[1]
        t := Integer(parts[2])
        switch type {
            case "MOVE":
                newEvents.Push(Map("t", t, "type", "move", "x", Integer(parts[3]), "y", Integer(parts[4])))
            case "KD":
                newEvents.Push(Map("t", t, "type", "keydown", "key", parts[3]))
            case "KU":
                newEvents.Push(Map("t", t, "type", "keyup", "key", parts[3]))
            case "MD":
                newEvents.Push(Map("t", t, "type", "mousedown", "btn", parts[3], "x", Integer(parts[4]), "y", Integer(parts[5])))
            case "MU":
                newEvents.Push(Map("t", t, "type", "mouseup", "btn", parts[3], "x", Integer(parts[4]), "y", Integer(parts[5])))
            case "WH":
                newEvents.Push(Map("t", t, "type", "wheel", "dir", parts[3]))
        }
    }
    return newEvents
}

SaveRecordingToFile(path) {
    global recordedEvents
    if FileExist(path)
        FileDelete(path)
    FileAppend(EventsToText(recordedEvents), path, "UTF-8")
}

LoadRecordingFromFile(path) {
    global recordedEvents
    if !FileExist(path)
        return false
    recordedEvents := TextToEvents(FileRead(path, "UTF-8"))
    return true
}

DoSaveRecording() {
    global recordedEvents, txtRecFile, recordingFilePath
    if recordedEvents.Length = 0 {
        MsgBox("Nothing recorded yet.", "Macro AIO", 48)
        return
    }
    path := FileSelect("S16", A_ScriptDir "\recording.actrec", "Save Recording", "Recording (*.actrec)")
    if path = ""
        return
    if !InStr(path, ".")
        path .= ".actrec"
    SaveRecordingToFile(path)
    recordingFilePath := path
    UpdateMacroFileLabel(path)
    txtRecFile.Text := "Saved: " path
}

DoExportRecording() {
    DoSaveRecording()
}

SaveRecordingCurrent() {
    ; The main Macro-tab Save button creates a named profile. The profile
    ; contains both recorder settings and the full event stream.
    DoSaveProfile()
}

DoLoadRecording() {
    global recordedEvents, txtRecFile, recordingFilePath
    path := FileSelect(1, A_ScriptDir, "Import Recording", "Recording (*.actrec)")
    if path = ""
        return
    if LoadRecordingFromFile(path) {
        recordingFilePath := path
        UpdateMacroFileLabel(path)
        txtRecFile.Text := "Loaded: " path " (" recordedEvents.Length " events)"
    } else {
        MsgBox("Could not load that file.", "Macro AIO", 48)
    }
    UpdateRecorderUI()
}

ClearRecording() {
    global recordedEvents, txtRecFile, recordingFilePath, macroStatusText
    recordedEvents := []
    recordingFilePath := ""
    UpdateMacroFileLabel("")
    txtRecFile.Text := "No recording."
    macroStatusText.Text := "Idle — ready"
    UpdateRecorderUI()
}

UpdateMacroFileLabel(path) {
    global ddMacroRecording
    name := path = "" ? "New recording" : ""
    if path != ""
        SplitPath(path, &name)
    ddMacroRecording.Delete()
    ddMacroRecording.Add([name])
    ddMacroRecording.Choose(1)
}

UpdateRecorderUI() {
    global recording, recordStartTick, recordedEvents, txtRecCount, txtRecDuration, macroSpeedText, eSpeed
    txtRecCount.Text := "Events: " recordedEvents.Length
    speedText := Trim(eSpeed.Text)
    if speedText = "" || !RegExMatch(speedText, "^-?\d+(\.\d+)?$")
        speedText := "100"
    macroSpeedText.Text := speedText "%"
    if recording {
        elapsed := (A_TickCount - recordStartTick) // 1000
        txtRecDuration.Text := "Duration: " FormatHMS(elapsed)
    } else {
        durationSec := recordedEvents.Length ? (recordedEvents[recordedEvents.Length]["t"] // 1000) : 0
        txtRecDuration.Text := "Duration: " FormatHMS(durationSec)
    }
}

; ---------------- Profile Manager ----------------
ChooseByText(ctrl, options, text) {
    for i, opt in options {
        if opt = text {
            ctrl.Choose(i)
            return true
        }
    }
    return false
}

profilesDir := A_ScriptDir "\Profiles"
DirCreate(profilesDir)

ListProfileNames() {
    global profilesDir
    names := []
    loop files, profilesDir "\*.profile" {
        SplitPath(A_LoopFileName, , , , &nameNoExt)
        names.Push(nameNoExt)
    }
    return names
}

RefreshProfileList() {
    global ddProfiles
    names := ListProfileNames()
    ddProfiles.Delete()
    if names.Length = 0
        ddProfiles.Add(["(no profiles saved)"])
    else
        ddProfiles.Add(names)
    ddProfiles.Choose(1)
}

DoSaveProfile() {
    global profilesDir, txtProfileStatus, ddMacroRecording, txtRecFile, ddProfiles
    global ddMode, ddHotkey, ddButton, ddType, ddRepeat, eCount, eHours, eMins, eSecs, eMs
    global chkFailsafe, ddKeyPress, targetTitle, clickX, clickY
    global chkRecordMoves, ddPlayRepeat, eSpeed, recordedEvents
    global chkHighSpeed, eHsCps

    name := ""
    result := InputBox("Enter a name for this profile:", "Save Profile", "w300 h120")
    if result.Result != "OK" || Trim(result.Value) = ""
        return
    name := Trim(result.Value)
    ; Strip characters that aren't safe in a filename
    name := RegExReplace(name, '[\\/:*?"<>|]', "_")

    lines := ""
    lines .= "Mode=" ddMode.Text "`n"
    lines .= "Hotkey=" ddHotkey.Value "`n"
    lines .= "Button=" ddButton.Text "`n"
    lines .= "Type=" ddType.Text "`n"
    lines .= "Repeat=" ddRepeat.Text "`n"
    lines .= "Count=" eCount.Text "`n"
    lines .= "Hours=" eHours.Text "`n"
    lines .= "Min=" eMins.Text "`n"
    lines .= "Sec=" eSecs.Text "`n"
    lines .= "Ms=" eMs.Text "`n"
    lines .= "Failsafe=" chkFailsafe.Value "`n"
    lines .= "HighSpeed=" chkHighSpeed.Value "`n"
    lines .= "HsCps=" eHsCps.Text "`n"
    lines .= "KeyPress=" ddKeyPress.Text "`n"
    lines .= "TargetTitle=" targetTitle "`n"
    lines .= "ClickX=" clickX "`n"
    lines .= "ClickY=" clickY "`n"
    lines .= "RecordMoves=" chkRecordMoves.Value "`n"
    lines .= "PlayRepeat=" ddPlayRepeat.Text "`n"
    lines .= "Speed=" eSpeed.Text "`n"
    lines .= "===EVENTS===`n"
    lines .= EventsToText(recordedEvents)

    path := profilesDir "\" name ".profile"
    if FileExist(path)
        FileDelete(path)
    FileAppend(lines, path, "UTF-8")
    RefreshProfileList()
    ddProfiles.Text := name
    ddMacroRecording.Delete()
    ddMacroRecording.Add([name])
    ddMacroRecording.Choose(1)
    txtRecFile.Text := "Saved profile macro: " name " (" recordedEvents.Length " events)"
    txtProfileStatus.Text := "Saved profile: " name " — macro + settings stored together."
    ShowPage("macroprofiles")
}

DoLoadProfile() {
    global profilesDir, ddProfiles, txtProfileStatus
    global ddMode, ddHotkey, ddButton, ddType, ddRepeat, eCount, eHours, eMins, eSecs, eMs
    global chkFailsafe, ddKeyPress, targetTitle, targetTopHwnd, targetHwnd, clickX, clickY, txtTarget, txtCoords
    global chkRecordMoves, ddPlayRepeat, eSpeed, recordedEvents, recordingFilePath
    global ddMacroRecording, txtRecFile
    global chkHighSpeed, eHsCps

    name := ddProfiles.Text
    if name = "" || name = "(no profiles saved)"
        return
    path := profilesDir "\" name ".profile"
    if !FileExist(path) {
        MsgBox("That profile file is missing.", "Macro AIO", 48)
        return
    }

    content := FileRead(path, "UTF-8")
    parts := StrSplit(content, ["===EVENTS===`n"])
    settingsText := parts[1]
    eventsText := parts.Length > 1 ? parts[2] : ""

    settings := Map()
    loop parse, settingsText, "`n", "`r" {
        if A_LoopField = "" || !InStr(A_LoopField, "=")
            continue
        kv := StrSplit(A_LoopField, "=", , 2)
        settings[kv[1]] := kv.Length > 1 ? kv[2] : ""
    }

    if settings.Has("Mode")
        ChooseByText(ddMode, ["Normal (click at cursor)", "Window Focus (background click)", "Key Press (auto-press key)"], settings["Mode"])
    UpdateModeUI()
    if settings.Has("Hotkey") && settings["Hotkey"] != "" {
        ddHotkey.Value := settings["Hotkey"]
        UpdateHotkey()
    }
    if settings.Has("Button")
        ChooseByText(ddButton, ["Left", "Right", "Middle"], settings["Button"])
    if settings.Has("Type")
        ChooseByText(ddType, ["Single", "Double"], settings["Type"])
    if settings.Has("Repeat")
        ChooseByText(ddRepeat, ["Until Stopped", "Fixed Count"], settings["Repeat"])
    if settings.Has("Count")
        eCount.Text := settings["Count"]
    if settings.Has("Hours")
        eHours.Text := settings["Hours"]
    if settings.Has("Min")
        eMins.Text := settings["Min"]
    if settings.Has("Sec")
        eSecs.Text := settings["Sec"]
    if settings.Has("Ms")
        eMs.Text := settings["Ms"]
    if settings.Has("Failsafe")
        chkFailsafe.Value := Integer(settings["Failsafe"])
    if settings.Has("HighSpeed")
        chkHighSpeed.Value := IsInteger(settings["HighSpeed"]) ? Integer(settings["HighSpeed"]) : 0
    if settings.Has("HsCps")
        eHsCps.Text := settings["HsCps"]
    if settings.Has("KeyPress")
        ChooseByText(ddKeyPress, KeyPressOptions(), settings["KeyPress"])
    if settings.Has("RecordMoves")
        chkRecordMoves.Value := Integer(settings["RecordMoves"])
    if settings.Has("PlayRepeat")
        ChooseByText(ddPlayRepeat, ["Play Once", "Repeat 3x", "Repeat 5x", "Repeat 10x", "Loop Until Stopped"], settings["PlayRepeat"])
    if settings.Has("Speed")
        eSpeed.Text := settings["Speed"]
    if settings.Has("ClickX")
        clickX := Integer(settings["ClickX"])
    if settings.Has("ClickY")
        clickY := Integer(settings["ClickY"])
    txtCoords.Text := "Click position: x=" clickX ", y=" clickY

    ; Best-effort: try to re-find the target window by its saved title
    if settings.Has("TargetTitle") && settings["TargetTitle"] != "" {
        targetTitle := settings["TargetTitle"]
        if WinExist(targetTitle) {
            targetTopHwnd := WinExist(targetTitle)
            targetHwnd := targetTopHwnd
            txtTarget.Text := "Target: " targetTitle " (relinked)"
        } else {
            targetTopHwnd := 0
            txtTarget.Text := "Target: " targetTitle " (not currently open)"
        }
    }

    recordedEvents := TextToEvents(eventsText)
    recordingFilePath := ""
    UpdateMacroFileLabel("")
    ddMacroRecording.Delete()
    ddMacroRecording.Add([name])
    ddMacroRecording.Choose(1)
    txtRecFile.Text := "Loaded profile macro: " name " (" recordedEvents.Length " events)"
    UpdateRecorderUI()

    txtProfileStatus.Text := "Loaded profile: " name " — " recordedEvents.Length " recorded events + saved settings."
    ShowPage("macro")
}

DoDeleteProfile() {
    global profilesDir, ddProfiles, txtProfileStatus
    name := ddProfiles.Text
    if name = "" || name = "(no profiles saved)"
        return
    if MsgBox("Delete profile '" name "'? This can't be undone.", "Macro AIO", 4 | 48) = "No"
        return
    path := profilesDir "\" name ".profile"
    if FileExist(path)
        FileDelete(path)
    RefreshProfileList()
    txtProfileStatus.Text := "Deleted profile: " name
}

; ---------------- Custom Gdip buttons ----------------
; Some Gdip_All.ahk builds don't include Gdip_AddPathArc / Gdip_ClosePathFigure,
; which caused "variable has not been assigned a value" here (AHK v2 treats an
; unrecognized name in call position as an uninitialized variable, not a missing
; function). These two tiny wrappers call the real GDI+ DLL directly so the
; rounded-rect drawing no longer depends on what that included library has.
_GdipAddPathArc(pPath, x, y, w, h, startAngle, sweepAngle) {
    return DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y, "float", w, "float", h, "float", startAngle, "float", sweepAngle)
}

_GdipClosePathFigure(pPath) {
    return DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)
}

AddRoundedRectPath(pPath, x, y, w, h, r) {
    d := r * 2
    _GdipAddPathArc(pPath, x, y, d, d, 180, 90)
    _GdipAddPathArc(pPath, x + w - d, y, d, d, 270, 90)
    _GdipAddPathArc(pPath, x + w - d, y + h - d, d, d, 0, 90)
    _GdipAddPathArc(pPath, x, y + h - d, d, d, 90, 90)
    try _GdipClosePathFigure(pPath)
}

LightenColor(hex, amt) {
    r := Integer("0x" SubStr(hex, 1, 2)) + amt
    g := Integer("0x" SubStr(hex, 3, 2)) + amt
    b := Integer("0x" SubStr(hex, 5, 2)) + amt
    r := r > 255 ? 255 : r
    g := g > 255 ? 255 : g
    b := b > 255 ? 255 : b
    return Format("{:02X}{:02X}{:02X}", r, g, b)
}

RenderButtonImage(path, w, h, text, top, bottom, hover) {
    topC := hover ? LightenColor(top, 25) : top
    botC := hover ? LightenColor(bottom, 25) : bottom
    pBitmap := Gdip_CreateBitmap(w, h)
    G := Gdip_GraphicsFromImage(pBitmap)
    Gdip_SetSmoothingMode(G, 4)
    pBrush := Gdip_CreateLineBrush(0, 0, 0, h, "0xFF" topC, "0xFF" botC, 1)
    pPath := Gdip_CreatePath()
    AddRoundedRectPath(pPath, 1, 1, w - 2, h - 2, 8)
    Gdip_FillPath(G, pBrush, pPath)
    Gdip_TextToGraphics(G, text, "x0 y0 w" w " h" h " cFFFFFFFF s10 Bold Center vCenter", "Bahnschrift")
    Gdip_SaveBitmapToFile(pBitmap, path)
    Gdip_DeletePath(pPath)
    Gdip_DeleteBrush(pBrush)
    Gdip_DeleteGraphics(G)
    Gdip_DisposeImage(pBitmap)
}

; Creates a rounded-gradient button with a hover-glow state, falling back to a
; plain native button if Gdip rendering fails for any reason.
MakeStyledButton(guiObj, x, y, w, h, text, callback, top, bottom) {
    ; Use a dark themed text control instead of a native Windows Button.
    ; Native buttons were inheriting the Windows light theme and showing as
    ; white rectangles. Text controls let the Diavolo palette stay consistent.
    global gdipButtons
    normal := top
    hover := LightenColor(top, 18)
    btn := guiObj.AddText("x" x " y" y " w" w " h" h " Background" normal " cF7EAF0 Center 0x200 Border", text)
    btn.OnEvent("Click", callback)
    gdipButtons.Push(Map("ctrl", btn, "x", x, "y", y, "w", w, "h", h
        , "normal", normal, "hover", hover, "state", "normal"))
    return btn
}

CheckButtonHover() {
    global gdipButtons, MyGui
    if gdipButtons.Length = 0
        return
    try
        WinGetClientPos(&gx, &gy, , , "ahk_id " MyGui.Hwnd)
    catch
        return
    MouseGetPos(&mx, &my)
    relX := mx - gx
    relY := my - gy
    for b in gdipButtons {
        inside := (relX >= b["x"] && relX <= b["x"] + b["w"] && relY >= b["y"] && relY <= b["y"] + b["h"])
        newState := inside ? "hover" : "normal"
        if newState != b["state"] {
            b["state"] := newState
            try b["ctrl"].Opt("Background" ((newState = "hover") ? b["hover"] : b["normal"]))
        }
    }
}

; ---------------- Window chrome (dark title bar + rounded corners) ----------------
HexToColorRef(hex) {
    r := Integer("0x" SubStr(hex, 1, 2))
    g := Integer("0x" SubStr(hex, 3, 2))
    b := Integer("0x" SubStr(hex, 5, 2))
    return (b << 16) | (g << 8) | r
}

ApplyDarkTitleBar(hwnd) {
    global accent
    val := 1
    ; DWMWA_USE_IMMERSIVE_DARK_MODE — attribute id differs slightly across Windows 10/11 builds
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 20, "int*", val, "int", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 19, "int*", val, "int", 4)
    ; DWMWA_WINDOW_CORNER_PREFERENCE — Windows 11 only, 2 = DWMWCP_ROUND
    pref := 2
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 33, "int*", pref, "int", 4)
    ; DWMWA_CAPTION_COLOR — Windows 11 only, tints the title bar with the theme accent
    clr := HexToColorRef(accent)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 35, "uint*", clr, "int", 4)
}

; ---------------- Games: Fisch auto-shake ----------------
DoChangeFischImage() {
    global fischImagePath, picFischRef, txtFischStatus, chkFischEnable

    wasEnabled := chkFischEnable.Value
    if wasEnabled {
        chkFischEnable.Value := 0
        StopFischShaking()
    }

    newPath := FileSelect(1, A_ScriptDir "\Assets", "Select Shake Reference Image", "Images (*.png; *.jpg; *.jpeg; *.bmp; *.gif)")
    if newPath = "" {
        txtFischStatus.Text := "Reference image unchanged."
        return
    }

    SplitPath(newPath, , , &ext)
    DirCreate(A_ScriptDir "\Assets")
    destPath := A_ScriptDir "\Assets\fisch_shake." (ext = "" ? "png" : ext)

    if destPath = newPath {
        fischImagePath := destPath
        picFischRef.Value := destPath
        txtFischStatus.Text := "Reference image updated — re-enable when ready."
        return
    }

    try {
        if FileExist(destPath)
            FileDelete(destPath)
        FileCopy(newPath, destPath)
        fischImagePath := destPath
        picFischRef.Value := destPath
        txtFischStatus.Text := "Reference image updated — re-enable when ready."
    } catch as e {
        MsgBox("Couldn't use that image: " e.Message, "Macro AIO", 48)
        txtFischStatus.Text := "Reference image unchanged."
    }
}

SetFischRegionCorner(which) {
    global fischRegionX1, fischRegionY1, fischRegionX2, fischRegionY2, txtFischRegion
    MouseGetPos(&mx, &my)
    if which = "TL" {
        fischRegionX1 := mx
        fischRegionY1 := my
    } else {
        fischRegionX2 := mx
        fischRegionY2 := my
    }
    UpdateFischRegionText()
}

UpdateFischRegionText() {
    global fischRegionX1, fischRegionY1, fischRegionX2, fischRegionY2, txtFischRegion
    if (fischRegionX1 = 0 && fischRegionY1 = 0 && fischRegionX2 = 0 && fischRegionY2 = 0) {
        txtFischRegion.Text := "Not set — currently scanning the WHOLE screen (slow)."
    } else if (fischRegionX2 > fischRegionX1 && fischRegionY2 > fischRegionY1) {
        w := fischRegionX2 - fischRegionX1
        h := fischRegionY2 - fischRegionY1
        txtFischRegion.Text := "Region: " fischRegionX1 "," fischRegionY1 " → " fischRegionX2 "," fischRegionY2 " (" w "x" h " px)"
    } else {
        txtFischRegion.Text := "Region set but invalid (bottom-right must be right and below top-left)."
    }
}

; ---------------- Default tab: user-defined custom image detectors ----------------
; Fully empty by default — the user adds detectors one at a time via
; "+ Add Detector...", each with its own reference image and chosen action.
; Nothing runs until the user ticks that slot's own "On" checkbox.

DoAddDefaultDetector() {
    global defaultDetectors, txtDefaultStatus, MAX_DEFAULT_SLOTS

    slot := 0
    for i, d in defaultDetectors {
        if !d["used"] {
            slot := i
            break
        }
    }
    if !slot {
        txtDefaultStatus.Text := "Max of " MAX_DEFAULT_SLOTS " detectors reached — remove one first."
        return
    }

    newPath := FileSelect(1, A_ScriptDir "\Assets", "Select Reference Image", "Images (*.png; *.jpg; *.jpeg; *.bmp; *.gif)")
    if newPath = ""
        return

    SplitPath(newPath, , , &ext)
    DirCreate(A_ScriptDir "\Assets")
    destPath := A_ScriptDir "\Assets\default_slot" slot "." (ext = "" ? "png" : ext)
    try {
        if FileExist(destPath)
            FileDelete(destPath)
        FileCopy(newPath, destPath, true)
    } catch as e {
        MsgBox("Couldn't use that image: " e.Message, "Macro AIO", 48)
        return
    }

    d := defaultDetectors[slot]
    d["used"] := true
    d["imgPath"] := destPath
    d["pic"].Value := destPath
    d["cooldownUntil"] := 0
    txtDefaultStatus.Text := "Detector " slot " added — tick its 'On' box to start watching for it."

    RefreshDefaultSlotVisibility()
}

RemoveDefaultDetectorSlot(slot, *) {
    global defaultDetectors, txtDefaultStatus
    d := defaultDetectors[slot]
    d["used"] := false
    d["enabled"] := false
    d["imgPath"] := ""
    d["cooldownUntil"] := 0
    d["chk"].Value := 0
    txtDefaultStatus.Text := "Detector " slot " removed."
    RefreshDefaultSlotVisibility()
}

ToggleDefaultDetectorSlot(slot, *) {
    global defaultDetectors, txtDefaultStatus
    d := defaultDetectors[slot]
    if !d["used"] {
        d["chk"].Value := 0
        return
    }
    d["enabled"] := d["chk"].Value
    d["cooldownUntil"] := 0
    txtDefaultStatus.Text := d["enabled"] ? "Detector " slot " watching..." : "Detector " slot " paused."
}

DefaultActionTypeChanged(slot, *) {
    global defaultDetectors
    d := defaultDetectors[slot]
    chosen := d["dd"].Text
    d["actionType"] := chosen
    ; Give a sane default param whenever the type changes and the field is empty
    if d["param"].Text = "" {
        if chosen = "Key Sequence"
            d["param"].Text := "Escape,Enter"
        else
            d["param"].Text := "Enter"
    }
}

; Re-hides every slot's row of controls that isn't in use, even while the
; Default tab itself is the selected page — so empty slots never show.
RefreshDefaultSlotVisibility() {
    global defaultDetectors
    for i, d in defaultDetectors {
        show := d["used"]
        for ctrl in [d["pic"], d["chk"], d["dd"], d["param"], d["remove"]]
            try ctrl.Opt(show ? "-Hidden" : "+Hidden")
    }
}

; Runs the action configured for a slot once it's been spotted on screen.
DefaultRunAction(d) {
    actionType := d["actionType"]
    param := Trim(d["param"].Text)

    if actionType = "Click" {
        Click(d["foundX"], d["foundY"])
    } else if actionType = "Press Key" {
        key := param = "" ? "Enter" : param
        Send("{Blind}{" key "}")
    } else if actionType = "Key Sequence" {
        keys := StrSplit(param = "" ? "Enter" : param, ",")
        for k in keys {
            k := Trim(k)
            if k != ""
                Send("{Blind}{" k "}")
            Sleep(150)
        }
    }
}

; Single shared scanner for every Default-tab detector. Runs continuously
; (cheap no-op when nothing is enabled) so slots can be toggled on/off freely.
DefaultTick() {
    global defaultDetectors
    now := A_TickCount
    for i, d in defaultDetectors {
        if !d["used"] || !d["enabled"]
            continue
        if now < d["cooldownUntil"]
            continue
        if !FileExist(d["imgPath"])
            continue

        found := false
        try found := ImageSearch(&fx, &fy, 0, 0, A_ScreenWidth, A_ScreenHeight, "*45 " d["imgPath"])
        catch {
            continue
        }
        if found {
            d["foundX"] := fx
            d["foundY"] := fy
            try DefaultRunAction(d)
            ; Short cooldown so one sighting doesn't fire the action nonstop —
            ; it'll fire again the next time it's (still) seen after this gap.
            d["cooldownUntil"] := now + 700
        }
    }
}

; ---------------- Bob Farm (Slap Battles) step sequence ----------------
; Setup: find+click Backpack, then Search -> type "replica" -> Equip -> X -> Esc,r,Enter.
; If Backpack is not found for 15s, skip the entire replica setup and enter the loop.
; Each step is a Map: {type: "click"/"key"/"type"/"hold", ...}. "setup" runs
; once after Enable; "loop" then repeats forever until Disable/kill switch.
; Every completed step is followed by a fixed bobFarmActionGapMs (1s) pause
; before the next one starts - that's the "1s interval between actions" ask.
BuildBobFarmSteps() {
    global bobBackpackImagePath, bobSearchImagePath, bobEquipImagePath, bobXImagePath, bobXFailsafeImagePath, bobPortalImagePath, bobPortalFailsafeImagePath
    global eFarmESpamCount, bobFarmSetupSteps, bobFarmLoopSteps

    spamCount := Integer(eFarmESpamCount.Text = "" ? 3 : eFarmESpamCount.Text)
    if spamCount < 1
        spamCount := 1

    bobFarmSetupSteps := [
        Map("type", "click", "img", bobBackpackImagePath, "label", "Backpack"),
        Map("type", "click", "img", bobSearchImagePath, "label", "Search"),
        Map("type", "type", "text", "replica", "label", "typing `"replica`""),
        Map("type", "click", "img", bobEquipImagePath, "label", "Equip"),
        Map("type", "click", "img", bobXImagePath, "label", "X"),
        Map("type", "keyseq", "keys", ["Escape", "r", "Enter"], "gapMs", 300, "label", "Esc,r,Enter")
    ]

    bobFarmLoopSteps := [
        Map("type", "wait", "ms", 3000, "label", "waiting 3s before scanning for Go To Portal")
        , Map("type", "portal", "img", bobPortalImagePath, "failsafeImg", bobPortalFailsafeImagePath
            , "timeoutMs", 2000, "label", "Go To Portal", "gapAfterMs", 400)
        , Map("type", "hold", "key", "s", "ms", 150, "label", "hold S (0.15s)", "noGapAfter", true)
        , Map("type", "hold", "key", "a", "ms", 300, "label", "hold A (0.3s)", "noGapAfter", true)
    ]
    loop spamCount
        bobFarmLoopSteps.Push(A_Index = spamCount
            ? Map("type", "key", "key", "e", "label", "spam E (" A_Index "/" spamCount ")", "gapAfterMs", 400)
            : Map("type", "key", "key", "e", "label", "spam E (" A_Index "/" spamCount ")"))
    bobFarmLoopSteps.Push(Map("type", "keyseq", "keys", ["Escape", "r", "Enter"], "gapMs", 300, "label", "Esc,r,Enter"))
}

UpdateBobFarmServerHopSetting() {
    global chkFarmServerHop, bobFarmServerHopStartTick, bobFarmRunning, bobFarmServerHopActive
    if chkFarmServerHop.Value {
        if bobFarmRunning && !bobFarmServerHopActive
            bobFarmServerHopStartTick := A_TickCount
    } else {
        bobFarmServerHopStartTick := 0
    }
}

StartBobServerHop(reason := "scheduled") {
    global bobFarmServerHopActive, bobFarmServerHopState, bobFarmServerHopStartTick, bobFarmServerHopReason
    global bobFarmHeldKey, txtFarmStatus

    if bobFarmHeldKey != "" {
        Send("{" bobFarmHeldKey " up}")
        bobFarmHeldKey := ""
    }

    bobFarmServerHopActive := true
    bobFarmServerHopState := "wait_play"
    bobFarmServerHopStartTick := 0
    bobFarmServerHopReason := reason
    bobFarmServerHopPreNudged := false
    txtFarmStatus.Text := (reason = "portal_failsafe")
        ? "Portal failsafe: 10 portal resets reached — rejoining..."
        : "Server Hop: Esc -> L -> Enter..."

    Send("{Escape}")
    Sleep(300)
    Send("{l}")
    Sleep(300)
    Send("{Enter}")

    ; After leaving the game the mouse cursor can vanish entirely - nudging
    ; it brings it back on screen instead of leaving it invisible/stuck for
    ; the rest of the wait_play phase.
    Sleep(300)
    MouseGetPos(&bobLeaveNudgeX, &bobLeaveNudgeY)
    MouseMove(bobLeaveNudgeX + 3, bobLeaveNudgeY + 3, 0)
    Sleep(50)
    MouseMove(bobLeaveNudgeX, bobLeaveNudgeY, 0)
}

BobServerHopTick() {
    global bobFarmServerHopActive, bobFarmServerHopState, bobFarmRunning
    global bobFarmServerHopStartTick, bobFarmActionGapMs, bobFarmServerHopReason
    global chkFarmServerHop, bobPlayImagePath, bobPlayFailsafeImagePath, txtFarmStatus
    global bobFarmPhase, bobFarmStepIdx, bobFarmState, bobFarmHoldStart, bobFarmNahCooldownAt, bobFarmXCooldownAt, bobFarmResetStreak, bobFarmBackpackWaitStart

    if !bobFarmRunning || !bobFarmServerHopActive
        return
    if bobFarmServerHopReason != "portal_failsafe" && !chkFarmServerHop.Value
        return

    if bobFarmServerHopState = "wait_play" {
        ; 20 seconds after Enter, begin looking for either play-button image.
        if !bobFarmServerHopStartTick
            bobFarmServerHopStartTick := A_TickCount
        elapsed := A_TickCount - bobFarmServerHopStartTick
        if elapsed < 20000 {
            ; One-shot nudge 3s before the search starts, so the cursor is
            ; already back on screen by the time ImageSearch begins instead
            ; of waiting for the first in-search nudge to bring it back.
            global bobFarmServerHopPreNudged
            if !bobFarmServerHopPreNudged && elapsed >= 17000 {
                bobFarmServerHopPreNudged := true
                MouseGetPos(&bobPreNudgeX, &bobPreNudgeY)
                MouseMove(bobPreNudgeX + 3, bobPreNudgeY + 3, 0)
                Sleep(50)
                MouseMove(bobPreNudgeX, bobPreNudgeY, 0)
            }
            txtFarmStatus.Text := (bobFarmServerHopReason = "portal_failsafe")
                ? "Portal failsafe: waiting " Round((20000 - elapsed) / 1000, 1) "s for Play..."
                : "Server Hop: waiting " Round((20000 - elapsed) / 1000, 1) "s for Play..."
            return
        }

        ; Without any input, the game can stop redrawing while idle, so
        ; ImageSearch keeps scanning a stale frame and never sees the Play
        ; button appear - that's the "had to move the mouse myself" bug.
        ; A tiny nudge each tick forces a fresh frame before every search.
        MouseGetPos(&bobHopNudgeX, &bobHopNudgeY)
        MouseMove(bobHopNudgeX + 1, bobHopNudgeY, 0)
        MouseMove(bobHopNudgeX, bobHopNudgeY, 0)

        if BobFindAndClickAny([bobPlayImagePath, bobPlayFailsafeImagePath], 20, 4) {
            bobFarmServerHopState := "wait_restart"
            bobFarmServerHopStartTick := A_TickCount
            txtFarmStatus.Text := (bobFarmServerHopReason = "portal_failsafe")
                ? "Portal failsafe: Play clicked — restarting in 20s..."
                : "Server Hop: Play clicked — restarting in 20s..."
        } else {
            txtFarmStatus.Text := (bobFarmServerHopReason = "portal_failsafe")
                ? "Portal failsafe: waiting for Play..."
                : "Server Hop: waiting for Play..."
        }
        return
    }

    if bobFarmServerHopState = "wait_restart" {
        elapsed := A_TickCount - bobFarmServerHopStartTick
        if elapsed < 20000 {
            txtFarmStatus.Text := (bobFarmServerHopReason = "portal_failsafe")
                ? "Portal failsafe: restarting farm in " Round((20000 - elapsed) / 1000, 1) "s..."
                : "Server Hop: restarting in " Round((20000 - elapsed) / 1000, 1) "s..."
            return
        }

        ; Restart the complete Bob Farm sequence from the setup stage.
        bobFarmServerHopActive := false
        bobFarmServerHopState := "idle"
        bobFarmServerHopStartTick := chkFarmServerHop.Value ? A_TickCount : 0
        bobFarmServerHopReason := ""
        bobFarmPhase := "setup"
        bobFarmStepIdx := 1
        bobFarmState := "acting"
        bobFarmHoldStart := 0
        bobFarmXCooldownAt := 0
        bobFarmNahCooldownAt := 0
        bobFarmResetStreak := 0
        bobFarmBackpackWaitStart := A_TickCount
        txtFarmStatus.Text := "Server Hop complete — restarting: attempting replica setup..."
    }
}

ToggleBobFarmHotkey(*) {
    global chkFarmEnable
    chkFarmEnable.Value := !chkFarmEnable.Value
    ToggleBobFarm()
}

ToggleBobFarm() {
    global chkFarmEnable, txtFarmStatus, bobFarmRunning, bobFarmPhase, bobFarmStepIdx, bobFarmState, bobFarmHoldStart
    global bobFarmBackpackWaitStart
    global bobBackpackImagePath, bobSearchImagePath, bobEquipImagePath, bobXImagePath, bobXFailsafeImagePath, bobPortalImagePath, bobPortalFailsafeImagePath, bobNahImagePath
    global bobPlayImagePath, bobPlayFailsafeImagePath, chkFarmServerHop, bobFarmServerHopActive, bobFarmServerHopState, bobFarmServerHopStartTick, bobFarmServerHopReason

    if chkFarmEnable.Value {
        for p in [bobBackpackImagePath, bobSearchImagePath, bobEquipImagePath, bobXImagePath, bobXFailsafeImagePath, bobPortalImagePath, bobPortalFailsafeImagePath, bobNahImagePath] {
            if !FileExist(p) {
                txtFarmStatus.Text := "Missing a reference image in Assets\ - re-add it."
                chkFarmEnable.Value := 0
                return
            }
        }
        if chkFarmServerHop.Value {
            for p in [bobPlayImagePath, bobPlayFailsafeImagePath] {
                if !FileExist(p) {
                    txtFarmStatus.Text := "Missing a Play reference image in Assets\ - re-add it."
                    chkFarmEnable.Value := 0
                    return
                }
            }
        }
        BuildBobFarmSteps()
        bobFarmRunning := true
        bobFarmServerHopActive := false
        bobFarmServerHopState := "idle"
        bobFarmServerHopStartTick := chkFarmServerHop.Value ? A_TickCount : 0
        bobFarmPhase := "setup"
        bobFarmStepIdx := 1
        bobFarmState := "acting"
        bobFarmHoldStart := 0
        bobFarmBackpackWaitStart := A_TickCount
        bobFarmXCooldownAt := 0
        bobFarmNahCooldownAt := 0
        txtFarmStatus.Text := "Setup: looking for Backpack..."
        SetTimer(BobFarmTick, 150)
    } else {
        StopBobFarm()
        txtFarmStatus.Text := "Disabled."
    }
}

StopBobFarm() {
    global bobFarmRunning, bobFarmPhase, bobFarmStepIdx, bobFarmState, bobFarmHoldStart, bobFarmHeldKey, bobFarmResetStreak
    global bobFarmBackpackWaitStart, bobFarmXCooldownAt, bobFarmNahCooldownAt
    global bobFarmServerHopActive, bobFarmServerHopState, bobFarmServerHopStartTick, bobFarmServerHopReason
    bobFarmRunning := false
    bobFarmPhase := "setup"
    bobFarmStepIdx := 1
    bobFarmState := "acting"
    bobFarmHoldStart := 0
    bobFarmResetStreak := 0
    bobFarmServerHopActive := false
    bobFarmServerHopState := "idle"
    bobFarmServerHopStartTick := 0
    bobFarmServerHopReason := ""
    bobFarmBackpackWaitStart := 0
    bobFarmXCooldownAt := 0
    bobFarmNahCooldownAt := 0
    SetTimer(BobFarmTick, 0)
    ; Failsafe: whatever stopped this (disable, kill switch, auto-stop), a
    ; movement key must never be left stuck down. Release unconditionally.
    if bobFarmHeldKey != "" {
        Send("{" bobFarmHeldKey " up}")
        bobFarmHeldKey := ""
    }
}

; Looks for imagePath anywhere on screen; if found, moves there and clicks.
; Returns true once the step is complete (found+clicked), false to keep waiting.
BobFindAndClick(imagePath, variation := 20, clickCount := 1) {
    found := false
    try found := ImageSearch(&ix, &iy, 0, 0, A_ScreenWidth, A_ScreenHeight, "*" variation " " imagePath)
    if found {
        ; Roblox can sometimes ignore an automated click when the cursor is
        ; already sitting on the matched point. Give the pointer a tiny real
        ; movement before returning it to the target, then use explicit mouse
        ; down/up clicks. Portal calls this with clickCount=4.
        MouseMove(ix, iy, 0)
        Sleep(15)
        MouseMove(ix + 2, iy + 1, 0)
        Sleep(15)
        MouseMove(ix - 1, iy, 0)
        Sleep(15)
        MouseMove(ix, iy, 0)
        Sleep(25)
        loop clickCount {
            Click("Left Down")
            Sleep(25)
            Click("Left Up")
            if A_Index < clickCount
                Sleep(80)
        }
        return true
    }
    return false
}

; Tries each image in imagePaths in turn, clicking the first one that matches
; anywhere on screen. Used where a button can legitimately look like one of
; a few slightly different references (e.g. a failsafe/alternate crop).
BobFindAndClickAny(imagePaths, variation := 20, clickCount := 1) {
    for imagePath in imagePaths {
        if BobFindAndClick(imagePath, variation, clickCount)
            return true
    }
    return false
}

; Shared fast reset sequence: Esc, r, Enter with a short 0.3s gap between each
; key (not the usual 1s inter-step gap) - used both as a normal farm step and
; as the Portal-not-found failsafe recovery.
BobEscREnterSequence(gapMs := 300) {
    Send("{Escape}")
    Sleep(gapMs)
    Send("{r}")
    Sleep(gapMs)
    Send("{Enter}")
}

; Performs one step's action. Returns true once that step is fully done
; (so the tick loop can start the 1s cooldown before the next step).
BobRunStep(step) {
    global bobFarmHoldStart, txtFarmStatus
    switch step["type"] {
        case "click":
            return BobFindAndClick(step["img"])
        case "key":
            Send("{" step["key"] "}")
            return true
        case "type":
            Send(step["text"])
            return true
        case "keyseq":
            for k in step["keys"] {
                Send("{" k "}")
                if A_Index < step["keys"].Length
                    Sleep(step["gapMs"])
            }
            return true
        case "portal":
            global bobFarmResetStreak, bobFarmResetStreakMax
            ; Try the normal reference image first, then the failsafe crop -
            ; either counts as "found" and gets clicked 4 times.
            if BobFindAndClickAny([step["img"], step["failsafeImg"]], 20, 4) {
                bobFarmHoldStart := 0
                bobFarmResetStreak := 0   ; portal found - the stuck/loop concern is over, reset the counter
                return true
            }
            if !bobFarmHoldStart {
                bobFarmHoldStart := A_TickCount
                return false
            }
            if A_TickCount - bobFarmHoldStart >= step["timeoutMs"] {
                ; Go To Portal hasn't shown up in time - reset via Esc,r,Enter
                ; (fast 0.3s gaps) and give it a fresh timeout window to try again.
                bobFarmResetStreak += 1
                if bobFarmResetStreak >= bobFarmResetStreakMax {
                    ; Portal failsafe is a REJOIN ONLY action. Never disable Bob Farm
                    ; or call StopBobFarm() here. Rejoin with Esc -> L -> Enter,
                    ; then wait for Play and restart the complete setup sequence.
                    txtFarmStatus.Text := Format("Portal not found after {1} resets — rejoining game...", bobFarmResetStreakMax)
                    StartBobServerHop("portal_failsafe")
                    bobFarmHoldStart := 0
                    return false
                }
                txtFarmStatus.Text := "Portal not seen for " Round(step["timeoutMs"] / 1000, 1) "s - resetting (Esc,r,Enter) [" bobFarmResetStreak "/" bobFarmResetStreakMax "]..."
                BobEscREnterSequence(300)
                bobFarmHoldStart := A_TickCount
            }
            return false
        case "hold":
            global bobFarmHeldKey
            if !bobFarmHoldStart {
                bobFarmHoldStart := A_TickCount
                bobFarmHeldKey := step["key"]
                Send("{" step["key"] " down}")
                return false
            }
            if A_TickCount - bobFarmHoldStart >= step["ms"] {
                Send("{" step["key"] " up}")
                bobFarmHeldKey := ""
                bobFarmHoldStart := 0
                return true
            }
            return false
        case "wait":
            if !bobFarmHoldStart {
                bobFarmHoldStart := A_TickCount
                return false
            }
            if A_TickCount - bobFarmHoldStart >= step["ms"] {
                bobFarmHoldStart := 0
                return true
            }
            return false
    }
    return true
}

BobFarmTick() {
    global bobFarmRunning, bobFarmPhase, bobFarmStepIdx, bobFarmState, bobFarmCooldownAt, bobFarmActionGapMs
    global bobFarmSetupSteps, bobFarmLoopSteps, bobNahImagePath, bobXImagePath, bobXFailsafeImagePath
    global bobFarmNahCooldownAt, bobFarmXCooldownAt, txtFarmStatus
    global bobFarmBackpackWaitStart, bobFarmBackpackTimeoutMs
    global chkFailsafe, chkFarmEnable, chkFarmServerHop, bobFarmServerHopActive, bobFarmServerHopStartTick, bobFarmServerHopState

    if !bobFarmRunning
        return

    ; Server Hop is a complete interruption of the farm sequence. Once triggered,
    ; no Nah/Portal/setup action runs until the hop finishes and the sequence resets.
    if (chkFarmServerHop.Value && !bobFarmServerHopActive && bobFarmServerHopStartTick > 0 && A_TickCount - bobFarmServerHopStartTick >= 600000) {
        StartBobServerHop()
    }

    if bobFarmServerHopActive {
        BobServerHopTick()
        SetTimer(BobFarmTick, 150)
        return
    }

    ; On every fresh setup (including after a server rejoin), give Backpack
    ; 15 seconds to appear. If it never appears, skip the entire replica
    ; equipping setup and continue directly into the normal farm loop.
    if bobFarmPhase = "setup" && bobFarmStepIdx = 1 {
        if !bobFarmBackpackWaitStart
            bobFarmBackpackWaitStart := A_TickCount
        if A_TickCount - bobFarmBackpackWaitStart >= bobFarmBackpackTimeoutMs {
            bobFarmPhase := "loop"
            bobFarmStepIdx := 1
            bobFarmState := "acting"
            bobFarmHoldStart := 0
            bobFarmBackpackWaitStart := 0
            txtFarmStatus.Text := "Backpack not found after 15s — skipping replica setup and starting farm loop."
        }
    }

    ; Shared failsafe (same one used by the clicker/playback): if the cursor
    ; hits the very bottom of the screen, stop everything immediately. This
    ; also guarantees any held movement key gets released via StopBobFarm().
    if IsSet(chkFailsafe) && chkFailsafe.Value {
        MouseGetPos(&bfMx, &bfMy)
        if bfMy >= A_ScreenHeight - 2 {
            chkFarmEnable.Value := 0
            StopBobFarm()
            txtFarmStatus.Text := "Failsafe triggered - cursor hit bottom of screen."
            ToolTip("Bob Farm failsafe triggered - cursor hit bottom of screen.")
            SetTimer(() => ToolTip(), -2000)
            return
        }
    }

    ; Nah is always-on while Bob Farm is running. X is different: the
    ; setup already contains the intentional X click after Equip, so the
    ; continuous X watcher only starts once the replica setup has finished
    ; and the farm has entered its normal loop.
    if A_TickCount >= bobFarmNahCooldownAt {
        if BobFindAndClick(bobNahImagePath) {
            bobFarmNahCooldownAt := A_TickCount + bobFarmActionGapMs
            txtFarmStatus.Text := "Saw `"Nah`" - clicked it."
            SetTimer(BobFarmTick, 150)
            return
        }
    }

    if bobFarmPhase = "loop" && A_TickCount >= bobFarmXCooldownAt {
        if BobFindAndClickAny([bobXImagePath, bobXFailsafeImagePath]) {
            bobFarmXCooldownAt := A_TickCount + bobFarmActionGapMs
            txtFarmStatus.Text := "Saw X - clicked it."
            SetTimer(BobFarmTick, 150)
            return
        }
    }

    steps := (bobFarmPhase = "setup") ? bobFarmSetupSteps : bobFarmLoopSteps

    if bobFarmState = "cooldown" {
        if A_TickCount >= bobFarmCooldownAt {
            bobFarmStepIdx += 1
            if bobFarmStepIdx > steps.Length {
                if bobFarmPhase = "setup" {
                    bobFarmPhase := "loop"
                } ; "loop" phase just wraps back to its own start
                bobFarmStepIdx := 1
                steps := (bobFarmPhase = "setup") ? bobFarmSetupSteps : bobFarmLoopSteps
            }
            bobFarmState := "acting"
            txtFarmStatus.Text := (bobFarmPhase = "setup" ? "Setup: " : "Loop: ") . steps[bobFarmStepIdx]["label"] . "..."
        }
        SetTimer(BobFarmTick, 150)
        return
    }

    ; bobFarmState = "acting"
    curStep := steps[bobFarmStepIdx]
    if BobRunStep(curStep) {
        if bobFarmPhase = "setup" && bobFarmStepIdx = 1
            bobFarmBackpackWaitStart := 0
        bobFarmState := "cooldown"
        ; Steps flagged noGapAfter skip the usual 1s inter-step gap entirely.
        ; A step can also specify an explicit "gapAfterMs" to use instead of
        ; the default 1s (e.g. a short 0.4s pause rather than none or 1s).
        if curStep.Has("gapAfterMs")
            gapMs := curStep["gapAfterMs"]
        else if (curStep.Has("noGapAfter") && curStep["noGapAfter"])
            gapMs := 0
        else
            gapMs := bobFarmActionGapMs
        bobFarmCooldownAt := A_TickCount + gapMs
    }

    if bobFarmRunning
        SetTimer(BobFarmTick, 150)
}

ToggleFisch() {
    global chkFischEnable, txtFischStatus, eFischInterval, fischShaking, fischImagePath

    if chkFischEnable.Value {
        if !FileExist(fischImagePath) {
            txtFischStatus.Text := "Reference image missing — reinstall Assets\fisch_shake.png."
            chkFischEnable.Value := 0
            return
        }
        interval := Integer(eFischInterval.Text = "" ? 150 : eFischInterval.Text)
        if interval < 50
            interval := 50
        fischShaking := false
        txtFischStatus.Text := "Watching for shake prompt..."
        ; FischTick does double duty: while idle it's the fast "is a shake
        ; starting" scan; while shaking it slows down to an "is it still
        ; going" recheck. Either way it never touches ENTER — that's
        ; FischSpam's job on its own fixed-rate timer, completely
        ; independent of when/whether a check happens to be running.
        SetTimer(FischTick, interval)
    } else {
        StopFischShaking()
        txtFischStatus.Text := "Disabled."
    }
}

; Single place that turns spamming off, so every code path (disable, kill
; switch) goes through the same clean stop.
StopFischShaking() {
    global fischShaking
    fischShaking := false
    SetTimer(FischTick, 0)
    SetTimer(FischSpam, 0)
}

FischTick() {
    global chkFischEnable, fischImagePath, eFischVariation, eFischMaxBurst, eFischInterval
    global txtFischStatus, fischShaking, fischShakeStart
    global fischRegionX1, fischRegionY1, fischRegionX2, fischRegionY2

    if !chkFischEnable.Value
        return

    interval := Integer(eFischInterval.Text = "" ? 150 : eFischInterval.Text)
    if interval < 50
        interval := 50

    ; While shaking, recheck on a slower, fixed cadence than the spam rate —
    ; this check is what eventually notices the shake ending, but it has
    ; zero influence on how often ENTER gets pressed in the meantime.
    recheckInterval := Max(interval, 200)

    if fischShaking {
        ; "Min spam" — once a shake is detected, this many ms are a locked
        ; floor: no re-check runs at all, so spam absolutely cannot be
        ; interrupted or stopped during this window no matter what the
        ; screen is doing. Only after it elapses do we start actually
        ; watching for the shake to end.
        minSpamMs := Integer(eFischMaxBurst.Text = "" ? 4000 : eFischMaxBurst.Text)
        elapsedShaking := A_TickCount - fischShakeStart

        ; Absolute safety ceiling, separate from the field above, purely so
        ; a broken detection region can't spam forever completely unnoticed.
        absoluteCapMs := 60000
        if elapsedShaking > absoluteCapMs {
            fischShaking := false
            SetTimer(FischSpam, 0)
            txtFischStatus.Text := "Stopped (hit absolute safety limit)."
            SetTimer(FischTick, interval)
            return
        }

        if elapsedShaking < minSpamMs {
            ; Still inside the guaranteed floor — don't even check, just
            ; keep spamming and try again once the floor has passed.
            SetTimer(FischTick, Min(recheckInterval, minSpamMs - elapsedShaking))
            return
        }
    }

    useRegion := (fischRegionX2 > fischRegionX1 && fischRegionY2 > fischRegionY1)
    sx1 := useRegion ? fischRegionX1 : 0
    sy1 := useRegion ? fischRegionY1 : 0
    sx2 := useRegion ? fischRegionX2 : A_ScreenWidth
    sy2 := useRegion ? fischRegionY2 : A_ScreenHeight
    variation := Integer(eFischVariation.Text = "" ? 15 : eFischVariation.Text)

    found := false
    try found := ImageSearch(&fx, &fy, sx1, sy1, sx2, sy2, "*" variation " " fischImagePath)
    catch {
        if fischShaking {
            fischShaking := false
            SetTimer(FischSpam, 0)
        }
        txtFischStatus.Text := "Image search error — try a different sensitivity or region."
        SetTimer(FischTick, interval)
        return
    }

    if found {
        if !fischShaking {
            ; First detection — start the independent spam timer immediately.
            ; From this point on, pressing ENTER has nothing to do with
            ; whether/when the next check runs.
            fischShaking := true
            fischShakeStart := A_TickCount
            txtFischStatus.Text := "Shake detected — spamming ENTER!"
            SetKeyDelay(-1, -1)
            SetTimer(FischSpam, 20)   ; fixed fast rate, ~50/sec
            FischSpam()               ; fire the very first press with no delay
        }
        SetTimer(FischTick, recheckInterval)
    } else {
        if fischShaking {
            fischShaking := false
            SetTimer(FischSpam, 0)
        }
        txtFischStatus.Text := "Watching for shake prompt..."
        SetTimer(FischTick, interval)
    }
}

; Purely mechanical: press ENTER on a fixed schedule for as long as
; fischShaking is true. Never calls ImageSearch, never waits on FischTick.
FischSpam() {
    global fischShaking
    if !fischShaking
        return
    Send("{Enter}")
}

; ---------------- Vision (GDI+ capture + color search) ----------------
CleanupVision() {
    global visionBitmap
    try SetTimer(WatchTick, 0)
    if visionBitmap
        Gdip_DisposeImage(visionBitmap)
    try FileDelete(A_ScriptDir "\.vision_thumb_a.png")
    try FileDelete(A_ScriptDir "\.vision_thumb_b.png")
}

CleanupButtonImages() {
    loop files, A_ScriptDir "\.btn_*.png"
        try FileDelete(A_LoopFileFullPath)
}

DoCaptureVision() {
    global targetTopHwnd, visionBitmap, visionOffsetX, visionOffsetY, visionWinX, visionWinY
    global txtCaptureInfo, picVisionThumb, visionThumbFlip

    if !targetTopHwnd || !WinExist("ahk_id " targetTopHwnd) {
        MsgBox("Select a Target Window on the Clicker tab first (Window Focus mode, Use Selected).", "Macro AIO", 48)
        return
    }

    if visionBitmap
        Gdip_DisposeImage(visionBitmap)

    visionBitmap := Gdip_BitmapFromHWND(targetTopHwnd)
    if !visionBitmap {
        txtCaptureInfo.Text := "Capture failed — try again or pick a different window."
        return
    }

    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " targetTopHwnd)
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " targetTopHwnd)
    visionWinX := wx
    visionWinY := wy
    visionOffsetX := cx - wx
    visionOffsetY := cy - wy

    w := Gdip_GetImageWidth(visionBitmap)
    h := Gdip_GetImageHeight(visionBitmap)
    txtCaptureInfo.Text := "Captured " w "x" h " px."

    ; Alternate thumbnail filenames so the Picture control never locks the file we're about to overwrite
    visionThumbFlip := !visionThumbFlip
    thumbPath := A_ScriptDir "\.vision_thumb_" (visionThumbFlip ? "a" : "b") ".png"
    Gdip_SaveBitmapToFile(visionBitmap, thumbPath)
    picVisionThumb.Value := thumbPath
}

ParseHexColor(text) {
    text := StrReplace(StrReplace(Trim(text), "0x", ""), "#", "")
    if StrLen(text) < 6
        return Map("r", 0, "g", 0, "b", 0)
    return Map("r", Integer("0x" SubStr(text, 1, 2))
             , "g", Integer("0x" SubStr(text, 3, 2))
             , "b", Integer("0x" SubStr(text, 5, 2)))
}

FindColorInBitmap(pBitmap, targetHex, tolerance) {
    if !pBitmap
        return Map("found", false)
    target := ParseHexColor(targetHex)
    w := Gdip_GetImageWidth(pBitmap)
    h := Gdip_GetImageHeight(pBitmap)
    loop h {
        y := A_Index - 1
        loop w {
            x := A_Index - 1
            argb := Gdip_GetPixel(pBitmap, x, y)
            r := (argb >> 16) & 0xFF
            g := (argb >> 8) & 0xFF
            b := argb & 0xFF
            if (Abs(r - target["r"]) <= tolerance && Abs(g - target["g"]) <= tolerance && Abs(b - target["b"]) <= tolerance)
                return Map("found", true, "x", x, "y", y)
        }
    }
    return Map("found", false)
}

DoFindColor() {
    global visionBitmap, eColorHex, eTolerance, txtFindResult, visionFoundX, visionFoundY

    if !visionBitmap {
        MsgBox("Capture the window first.", "Macro AIO", 48)
        return
    }
    tol := Integer(eTolerance.Text = "" ? 20 : eTolerance.Text)
    result := FindColorInBitmap(visionBitmap, eColorHex.Text, tol)
    if result["found"] {
        visionFoundX := result["x"]
        visionFoundY := result["y"]
        txtFindResult.Text := "Found at x=" visionFoundX ", y=" visionFoundY " (window-relative)"
    } else {
        visionFoundX := -1
        visionFoundY := -1
        txtFindResult.Text := "Color not found in this capture."
    }
}

DoMoveToFound() {
    global visionFoundX, visionFoundY, visionWinX, visionWinY
    if visionFoundX = -1 {
        MsgBox("Nothing found yet — run 'Find Color In Capture' first.", "Macro AIO", 48)
        return
    }
    MouseMove(visionWinX + visionFoundX, visionWinY + visionFoundY, 0)
}

DoClickFound() {
    global visionFoundX, visionFoundY, visionOffsetX, visionOffsetY, targetTopHwnd
    if visionFoundX = -1 {
        MsgBox("Nothing found yet — run 'Find Color In Capture' first.", "Macro AIO", 48)
        return
    }
    if !targetTopHwnd || !WinExist("ahk_id " targetTopHwnd)
        return
    SendBackgroundClick(targetTopHwnd, visionFoundX - visionOffsetX, visionFoundY - visionOffsetY, "Left")
}

ToggleWatch() {
    global visionWatching, btnWatch, eWatchInterval
    if visionWatching {
        visionWatching := false
        SetTimer(WatchTick, 0)
        btnWatch.Text := "Start Watching"
    } else {
        visionWatching := true
        interval := Integer(eWatchInterval.Text = "" ? 500 : eWatchInterval.Text)
        if interval < 100
            interval := 100
        btnWatch.Text := "Stop Watching"
        SetTimer(WatchTick, interval)
    }
}

WatchTick() {
    global visionWatching, chkAutoWatch, visionFoundX
    if !visionWatching
        return
    DoCaptureVision()
    DoFindColor()
    if (chkAutoWatch.Value && visionFoundX != -1)
        DoClickFound()
}

; ---------------- Session/lifetime stats ----------------
FormatHMS(totalSec) {
    hh := totalSec // 3600
    mm := Mod(totalSec, 3600) // 60
    ss := Mod(totalSec, 60)
    return Format("{:02}:{:02}:{:02}", hh, mm, ss)
}

FormatNum(n) {
    s := String(n)
    cnt := 0
    loop parse, s
        cnt += 1
    out := "", i := 0
    loop parse, s {
        out .= A_LoopField
        i += 1
        if (Mod(cnt - i, 3) = 0 && i < cnt)
            out .= ","
    }
    return out
}

UpdateStatsDisplay() {
    global sessionClicks, appStartTick, lifetimeClicks, totalSessions
    global longestSession, peakCpsEver, sessionPeakCps
    global txtDuration, txtAvgCps, txtPeakCps, txtLifeClicks, txtTotalSessions, txtLongestSession, txtPeakEver

    sessionElapsedSec := (A_TickCount - appStartTick) // 1000
    txtDuration.Text := FormatHMS(sessionElapsedSec)

    avgCps := sessionElapsedSec > 0 ? Round(sessionClicks / sessionElapsedSec, 1) : 0.0
    txtAvgCps.Text := avgCps
    txtPeakCps.Text := Round(sessionPeakCps, 1)

    txtLifeClicks.Text := FormatNum(lifetimeClicks)
    txtTotalSessions.Text := totalSessions
    txtLongestSession.Text := FormatHMS(Max(longestSession, sessionElapsedSec))
    txtPeakEver.Text := Round(Max(peakCpsEver, sessionPeakCps), 1) " CPS"
}

ResetSession() {
    global sessionClicks, appStartTick, sessionPeakCps, cpsWindowStart, cpsWindowCount
    global txtSessionClicks, txtLiveCps
    sessionClicks := 0
    appStartTick := A_TickCount
    sessionPeakCps := 0.0
    cpsWindowStart := A_TickCount
    cpsWindowCount := 0
    txtSessionClicks.Text := "0"
    txtLiveCps.Text := "0.0"
    UpdateStatsDisplay()
}

ResetLifetime() {
    global lifetimeClicks, totalSessions, lifetimeRuntime, longestSession, peakCpsEver, dataFile
    result := MsgBox("This permanently resets your lifetime click count, session count, and records. Continue?", "Reset Lifetime Stats", "YesNo 48")
    if result = "Yes" {
        lifetimeClicks := 0
        totalSessions := 1
        lifetimeRuntime := 0
        longestSession := 0
        peakCpsEver := 0.0
        IniWrite(0, dataFile, "Stats", "LifetimeClicks")
        IniWrite(1, dataFile, "Stats", "TotalSessions")
        IniWrite(0, dataFile, "Stats", "LifetimeRuntimeSec")
        IniWrite(0, dataFile, "Stats", "LongestSessionSec")
        IniWrite(0, dataFile, "Stats", "PeakCpsEver")
        UpdateStatsDisplay()
    }
}

CopyStats() {
    global sessionClicks, lifetimeClicks, totalSessions, appStartTick
    global txtAvgCps, txtPeakCps
    sessionElapsedSec := (A_TickCount - appStartTick) // 1000
    txt := "Macro AIO Stats`n"
        . "Session clicks: " sessionClicks "`n"
        . "Session time: " FormatHMS(sessionElapsedSec) "`n"
        . "Avg CPS (session): " txtAvgCps.Text "`n"
        . "Peak CPS (session): " txtPeakCps.Text "`n"
        . "Lifetime clicks: " FormatNum(lifetimeClicks) "`n"
        . "Total sessions: " totalSessions
    A_Clipboard := txt
    ToolTip("Copied stats to clipboard.")
    SetTimer(() => ToolTip(), -1200)
}

SetTimer(UpdateStatsDisplay, 500)
SetTimer(DefaultTick, 200)
SetTimer(SaveLifetimeData, 5000)

SaveLifetimeData() {
    global lifetimeClicks, totalSessions, lifetimeRuntime, longestSession, peakCpsEver, sessionPeakCps, appStartTick, dataFile
    sessionElapsedSec := (A_TickCount - appStartTick) // 1000
    IniWrite(lifetimeClicks, dataFile, "Stats", "LifetimeClicks")
    IniWrite(lifetimeRuntime + sessionElapsedSec, dataFile, "Stats", "LifetimeRuntimeSec")
    IniWrite(Max(longestSession, sessionElapsedSec), dataFile, "Stats", "LongestSessionSec")
    IniWrite(Max(peakCpsEver, sessionPeakCps), dataFile, "Stats", "PeakCpsEver")
}

; ---------------- Init ----------------
DllCall("winmm\timeBeginPeriod", "uint", 1)
MyGui.OnEvent("Close", (*) => (CleanupVision(), CleanupButtonImages(), SaveLifetimeData(), Gdip_Shutdown(gdipToken), DllCall("winmm\timeEndPeriod", "uint", 1), ExitApp()))
UpdateHotkey()
UpdateTypingTestHotkey()
UpdateBtdHotkey()
UpdateStatsDisplay()
Hotkey("F2", ToggleRecording, "On")
if playbackToggleKey != ""
    try Hotkey(playbackToggleKey, TogglePlayback, "On")
Hotkey("Del", KillSwitch, "On")
Hotkey("~LButton", GlobalLButtonDown, "On")
Hotkey("~LButton Up", GlobalLButtonUp, "On")
SetTimer(UpdateRecorderUI, 200)
SetTimer(CheckButtonHover, 60)
UpdateRecorderUI()
RefreshProfileList()
ApplyDarkTitleBar(MyGui.Hwnd)
MyGui.Show("w760 h560")
