#Requires AutoHotkey v2.0
#SingleInstance Force

; Agent Prompt Picker - keyboard-first, dependency-free AHK v2 tool.
; YAML parsing supports the small subset documented in README.md.

configPath := A_ScriptDir "\prompts.yml"
prompts := []
visibleRows := []
lastTarget := 0

; Two-pane, keyboard-first interface.
; Left: incremental all-field search + two-column Category/Command list.
; Right: Japanese details title + full prompt content.
; Behaves like a command palette: hides automatically when another window is activated.
appGui := Gui("+AlwaysOnTop +Resize +MinSize760x380", "Agent Prompt Picker")
appGui.MarginX := 16
appGui.MarginY := 14
appGui.SetFont("s10", "Segoe UI")
searchBox := appGui.AddEdit("x16 y16 w330 h28")
; Native Windows edit hint. This is not a separate heading.
DllCall("SendMessageW", "ptr", searchBox.Hwnd, "uint", 0x1501,
    "ptr", 0, "wstr", "検索", "ptr")
appGui.SetFont("s9", "Segoe UI")  ; One size smaller for the command list only.
listView := appGui.AddListView("x16 y54 w330 h410 -Multi NoSortHdr", ["Category", "Command"])
appGui.SetFont("s10", "Segoe UI")
listView.ModifyCol(1, 78)
listView.ModifyCol(2, 222)
detailTitle := appGui.AddText("x364 y20 w600 h23", "詳細")  ; Displays the YAML details field.
previewBox := appGui.AddEdit("x364 y54 w600 h410 ReadOnly +VScroll", "")
appGui.SetFont("s9", "Segoe UI")
footerText := appGui.AddText("x16 y482 w948 h24",
    " Ctrl+Enter コピー  | Ctrl+E 編集  |  Ctrl+R 再読込")

appGui.OnEvent("Close", (*) => appGui.Hide())
appGui.OnEvent("Escape", (*) => EscapeOrPass())
appGui.OnEvent("Size", OnPickerSize)
; Gui has no built-in Deactivate event. WM_ACTIVATE (WA_INACTIVE) is used
; to detect when the user switches to a different window or clicks outside.
OnMessage(0x0006, OnPickerActivate)
searchBox.OnEvent("Change", (*) => RefreshList())
listView.OnEvent("ItemSelect", OnItemSelect)
listView.OnEvent("DoubleClick", (ctrl, row) => PasteSelected(row))

; These hotkeys only take effect when this GUI is the active window.
; Search stays focused while Up/Down changes the ListView selection.
HotIfWinActive("ahk_id " appGui.Hwnd)
Hotkey("$Up", (*) => NavigateOrPass(-1, "Up"))
Hotkey("$Down", (*) => NavigateOrPass(1, "Down"))
Hotkey("^k", (*) => MoveSelection(-1))
Hotkey("^j", (*) => MoveSelection(1))
Hotkey("$Enter", (*) => EnterOrPass("Enter"))
Hotkey("$NumpadEnter", (*) => EnterOrPass("NumpadEnter"))
Hotkey("^Enter", (*) => CopySelected())
Hotkey("^NumpadEnter", (*) => CopySelected())
Hotkey("$Escape", (*) => EscapeOrPass())
Hotkey("^e", (*) => EditYaml())
Hotkey("^r", (*) => ReloadPrompts())
Hotkey("^f", (*) => searchBox.Focus())
HotIfWinActive()
Hotkey("^!p", TogglePicker)

A_TrayMenu.Add("検索ウィンドウを開く", (*) => TogglePicker())
A_TrayMenu.Add("YAMLを編集", (*) => EditYaml())
A_TrayMenu.Add("再読み込み", (*) => ReloadPrompts())
A_TrayMenu.Add()
A_TrayMenu.Add("終了", (*) => ExitApp())

; Establish initial dimensions without showing the picker.
appGui.Show("Hide w980 h520")
ReloadPrompts()

; Windows sends WM_ACTIVATE to top-level windows on activation changes.
; Only react to this picker being deactivated (LOWORD(wParam) == WA_INACTIVE).
; Defer hiding until after the Windows focus change has completed.
OnPickerActivate(wParam, lParam, msg, hwnd) {
    global appGui
    if (hwnd != appGui.Hwnd || (wParam & 0xFFFF) != 0)
        return
    SetTimer(HidePickerIfInactive, -30)
}

HidePickerIfInactive() {
    global appGui
    if (DllCall("IsWindowVisible", "ptr", appGui.Hwnd, "int")
        && !WinActive("ahk_id " appGui.Hwnd))
        appGui.Hide()
}

; Resize both columns with the window. Keep enough room for the footer.
OnPickerSize(guiObj, minMax, clientW, clientH) {
    global searchBox, listView, detailTitle, previewBox, footerText
    if (minMax = -1)
        return
    ; 70% of v7's 48% left pane; give the freed space to the preview.
    leftW := Max(270, Round(clientW * 0.336))
    rightX := 16 + leftW + 18
    rightW := Max(240, clientW - rightX - 16)
    listH := Max(250, clientH - 110)
    searchBox.Move(16, 16, leftW, 28)
    listView.Move(16, 54, leftW, listH)
    categoryW := Max(65, Min(120, Round(leftW * 0.235)))
    listView.ModifyCol(1, categoryW)
    listView.ModifyCol(2, Max(150, leftW - categoryW - 30))
    detailTitle.Move(rightX, 20, rightW, 23)
    previewBox.Move(rightX, 54, rightW, listH)
    footerText.Move(16, clientH - 33, clientW - 32, 24)
}

TogglePicker(*) {
    global appGui, searchBox, lastTarget
    if WinActive("ahk_id " appGui.Hwnd) {
        appGui.Hide()
        return
    }

    ; Remember the original target before opening the picker.
    lastTarget := WinExist("A")
    searchBox.Value := ""
    ReloadPrompts()
    appGui.Show("Center")
    searchBox.Focus()
}

ReloadPrompts(*) {
    global configPath, prompts
    try {
        newPrompts := ReadPromptFile(configPath)
        SortPrompts(newPrompts)
        prompts := newPrompts
        RefreshList()
    } catch Error as err {
        MsgBox("YAMLの読み込みに失敗しました。`n`n" err.Message,
            "Agent Prompt Picker", "Iconx")
    }
}

; Stable, case-insensitive sort by Category, then Command. Equal keys retain
; their original YAML order. Sort the data, not the ListView, so row mapping
; remains correct when filtering, previewing and pasting.
SortPrompts(items) {
    ; Insertion sort keeps equal keys in source order. Prompt lists are small.
    Loop items.Length {
        i := A_Index
        if (i = 1)
            continue
        item := items[i]
        j := i - 1
        while (j >= 1 && ComparePrompts(items[j], item) > 0) {
            items[j + 1] := items[j]
            j -= 1
        }
        items[j + 1] := item
    }
}

ComparePrompts(a, b) {
    cmp := StrCompare(a["category"], b["category"], false)
    return (cmp != 0) ? cmp : StrCompare(a["command"], b["command"], false)
}

RefreshList(*) {
    global prompts, visibleRows, listView, searchBox, previewBox, detailTitle
    visibleRows := []
    listView.Opt("-Redraw")
    listView.Delete()

    ; Incremental AND search across all fields, including the prompt body.
    query := StrReplace(Trim(searchBox.Value), "　", " ")
    words := StrSplit(query, " ")
    for index, prompt in prompts {
        haystack := prompt["category"] " " prompt["command"] " " prompt["details"] " " prompt["content"] " " prompt["trigger"]
        matched := true
        for word in words {
            if (word != "" && !InStr(haystack, word, false)) {
                matched := false
                break
            }
        }
        if !matched
            continue
        visibleRows.Push(index)
        listView.Add("", prompt["category"], prompt["command"])
    }
    listView.Opt("+Redraw")
    previewBox.Value := ""
    detailTitle.Text := "詳細"
    if visibleRows.Length {
        listView.Modify(1, "Select Focus Vis")
        ShowPreview(1)
    }
}

; During Japanese IME conversion, leave the arrow/Enter/Escape keys to IME.
; The $-prefixed hotkeys above prevent Send from recursively triggering them.
IsImeComposing() {
    global appGui, searchBox
    if (appGui.FocusedCtrl != searchBox)
        return false
    himc := DllCall("imm32\ImmGetContext", "ptr", searchBox.Hwnd, "ptr")
    if !himc
        return false
    length := DllCall("imm32\ImmGetCompositionStringW", "ptr", himc,
        "uint", 0x0008, "ptr", 0, "uint", 0, "int")
    DllCall("imm32\ImmReleaseContext", "ptr", searchBox.Hwnd, "ptr", himc)
    return length > 0
}

NavigateOrPass(direction, keyName) {
    if IsImeComposing() {
        Send("{" keyName "}")
        return
    }
    MoveSelection(direction)
}

EnterOrPass(keyName) {
    if IsImeComposing() {
        Send("{" keyName "}")
        return
    }
    PasteSelected()
}

EscapeOrPass() {
    global appGui, searchBox
    ; Let the IME cancel conversion before changing the search query.
    if IsImeComposing() {
        Send("{Escape}")
        return
    }
    ; First Esc clears the search; a second Esc hides the picker.
    if (searchBox.Value != "") {
        searchBox.Value := ""
        RefreshList()  ; Programmatic Edit.Value changes may not fire Change.
        searchBox.Focus()
        return
    }
    appGui.Hide()
}

MoveSelection(direction) {
    global listView, visibleRows
    if !visibleRows.Length
        return
    row := listView.GetNext()  ; No second argument: default = selected row.
    if !row
        row := 1
    else
        row := Max(1, Min(visibleRows.Length, row + direction))
    listView.Modify(0, "-Select")
    listView.Modify(row, "Select Focus Vis")
    ShowPreview(row)
    ; Intentionally do not focus listView: typing continues in the search box.
}

OnItemSelect(ctrl, row, selected) {
    if selected
        ShowPreview(row)
}

ShowPreview(row) {
    global previewBox, detailTitle, visibleRows, prompts
    if (row < 1 || row > visibleRows.Length) {
        detailTitle.Text := "詳細"
        previewBox.Value := ""
        return
    }
    prompt := prompts[visibleRows[row]]
    detailTitle.Text := (prompt["details"] != "") ? prompt["details"] : prompt["command"]
    previewBox.Value := prompt["content"]
}

PromptAtRow(row) {
    global visibleRows, prompts
    if (row < 1 || row > visibleRows.Length)
        return ""
    return prompts[visibleRows[row]]["content"]
}

SelectedPrompt() {
    global listView
    return PromptAtRow(listView.GetNext())
}

CopySelected(*) {
    prompt := SelectedPrompt()
    if (prompt = "")
        return
    A_Clipboard := prompt
}

PasteSelected(row := 0) {
    global appGui, lastTarget
    prompt := row ? PromptAtRow(row) : SelectedPrompt()
    if (prompt = "")
        return

    A_Clipboard := prompt
    if !ClipWait(0.8) {
        MsgBox("クリップボードにコピーできませんでした。", "Agent Prompt Picker", "Iconx")
        return
    }

    appGui.Hide()
    if (lastTarget && WinExist("ahk_id " lastTarget)) {
        target := "ahk_id " lastTarget
        WinActivate(target)
        if WinWaitActive(target, , 1.5) {
            Sleep(70)
            Send("^v")
        } else {
            MsgBox("元のウィンドウに切り替えられませんでした。`n"
                "プロンプトはクリップボードにコピー済みです。", "Agent Prompt Picker")
        }
    } else {
        MsgBox("貼り付け先のウィンドウがありません。`n"
            "プロンプトはクリップボードにコピー済みです。", "Agent Prompt Picker")
    }
}

EditYaml(*) {
    global configPath
    Run('notepad.exe "' configPath '"')
}

; Supported YAML subset (legacy label/replace/trigger accepted as input aliases):
; matches:
;   - category: "Agent"
;     command: "Review Changes"  ; Short English name shown in the list
;     details: "変更差分をレビュー"  ; Japanese heading in the preview
;     content: |
;       Review the current changes...
; No external YAML package is needed.
ReadPromptFile(path) {
    if !FileExist(path)
        throw Error("設定ファイルがありません: " path)

    source := StrReplace(FileRead(path, "UTF-8"), "`r", "")
    source := LTrim(source, Chr(0xFEFF))
    lines := StrSplit(source, "`n")
    items := []
    current := NewPrompt()
    hasEntry := false
    inBlock := false
    blockIndent := 0

    for line in lines {
        if inBlock {
            if (Trim(line) = "") {
                current["content"] .= "`n"
                continue
            }
            indent := StrLen(line) - StrLen(LTrim(line, " "))
            if (indent >= 6) {
                if (blockIndent = 0)
                    blockIndent := indent
                if (indent >= blockIndent) {
                    current["content"] .= SubStr(line, blockIndent + 1) "`n"
                    continue
                }
            }
            inBlock := false
        }

        ; Entries begin with a two-space dash; field values use four-space indents.
        if RegExMatch(line, "^  - (command|details|content|category|trigger|label|replace):[ \t]*(.*)$", &match) {
            if hasEntry
                AddIfValid(items, current)
            current := NewPrompt()
            hasEntry := true
            ParseField(current, match[1], match[2], &inBlock, &blockIndent)
            continue
        }
        if (hasEntry && RegExMatch(line, "^    (command|details|content|category|trigger|label|replace):[ \t]*(.*)$", &match)) {
            ParseField(current, match[1], match[2], &inBlock, &blockIndent)
            continue
        }
        if RegExMatch(line, "^  - ")
            throw Error("未対応のYAMLエントリです: " line)
    }
    if hasEntry
        AddIfValid(items, current)
    return items
}

NewPrompt() {
    return Map("category", "", "command", "", "details", "", "content", "", "trigger", "")
}

ParseField(prompt, field, rawValue, &inBlock, &blockIndent) {
    ; Old YAML files can be opened without immediate migration.
    if (field = "label") {
        field := "details"
    } else if (field = "replace") {
        field := "content"
    }

    value := Trim(rawValue)
    if (field = "content" && (value = "|" || value = "|-")) {
        prompt["content"] := ""
        inBlock := true
        blockIndent := 0
    } else {
        prompt[field] := Unquote(value)
    }
}

AddIfValid(items, prompt) {
    prompt["content"] := RTrim(prompt["content"], "`n")
    if (prompt["content"] = "")
        return
    if (prompt["command"] = "")
        prompt["command"] := (prompt["details"] != "") ? prompt["details"] : (prompt["trigger"] != "" ? prompt["trigger"] : "Untitled")
    if (prompt["details"] = "")
        prompt["details"] := prompt["command"]
    if (prompt["category"] = "")
        prompt["category"] := "General"
    items.Push(prompt)
}

Unquote(value) {
    value := Trim(value)
    if (StrLen(value) >= 2) {
        first := SubStr(value, 1, 1)
        last := SubStr(value, -1)
        if ((first = Chr(34) && last = Chr(34)) || (first = "'" && last = "'"))
            return SubStr(value, 2, StrLen(value) - 2)
    }
    return value
}
