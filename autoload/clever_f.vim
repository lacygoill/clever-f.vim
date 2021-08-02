vim9script noclear

# constants
var ON_NVIM: bool = has('nvim')
var ESC_CODE: number = char2nr("\<Esc>")
var HAS_TIMER: bool = has('timers')

var moved_forward: number

# configurations
g:clever_f_across_no_line          = get(g:, 'clever_f_across_no_line', 0)
g:clever_f_ignore_case             = get(g:, 'clever_f_ignore_case', 0)
g:clever_f_use_migemo              = get(g:, 'clever_f_use_migemo', 0)
g:clever_f_fix_key_direction       = get(g:, 'clever_f_fix_key_direction', 0)
g:clever_f_show_prompt             = get(g:, 'clever_f_show_prompt', 0)
g:clever_f_smart_case              = get(g:, 'clever_f_smart_case', 0)
g:clever_f_chars_match_any_signs   = get(g:, 'clever_f_chars_match_any_signs', '')
g:clever_f_mark_cursor             = get(g:, 'clever_f_mark_cursor', 1)
g:clever_f_hide_cursor_on_cmdline  = get(g:, 'clever_f_hide_cursor_on_cmdline', 1)
g:clever_f_timeout_ms              = get(g:, 'clever_f_timeout_ms', 0)
g:clever_f_mark_char               = get(g:, 'clever_f_mark_char', 1)
g:clever_f_repeat_last_char_inputs = get(g:, 'clever_f_repeat_last_char_inputs', ["\<CR>"])
g:clever_f_mark_direct             = get(g:, 'clever_f_mark_direct', 0)
g:clever_f_highlight_timeout_ms    = get(g:, 'clever_f_highlight_timeout_ms', 0)

# below variable must be set before loading this script
g:clever_f_clean_labels_eagerly    = get(g:, 'clever_f_clean_labels_eagerly', 1)

# highlight labels
augroup plugin-clever-f-highlight
    autocmd!
    autocmd ColorScheme * highlight default CleverFDefaultLabel ctermfg=red ctermbg=NONE cterm=bold,underline guifg=red guibg=NONE gui=bold,underline
augroup END
highlight default CleverFDefaultLabel ctermfg=red ctermbg=NONE cterm=bold,underline guifg=red guibg=NONE gui=bold,underline

# Priority of highlight customization is:
#   High:   When g:clever_f_*_color
#   Middle: :highlight in a colorscheme
#   Low:    Default highlights
# When the variable is defined, it should be linked with :hi! since :hi does
# not overwrite existing highlight group. (#50)
if g:clever_f_mark_cursor
    if exists('g:clever_f_mark_cursor_color')
        execute 'highlight! link CleverFCursor' g:clever_f_mark_cursor_color
    else
        highlight link CleverFCursor Cursor
    endif
endif
if g:clever_f_mark_char
    if exists('g:clever_f_mark_char_color')
        execute 'highlight! link CleverFChar' g:clever_f_mark_char_color
    else
        highlight link CleverFChar CleverFDefaultLabel
    endif
endif
if g:clever_f_mark_direct
    if exists('g:clever_f_mark_direct_color')
        execute 'highlight! link CleverFDirect' g:clever_f_mark_direct_color
    else
        highlight link CleverFDirect CleverFDefaultLabel
    endif
endif

if g:clever_f_clean_labels_eagerly
    augroup plugin-clever-f-permanent-finalizer
        autocmd!
        autocmd WinEnter,WinLeave,CmdwinLeave * {
            if g:clever_f_mark_char
                RemoveHighlight()
            endif
        }
    augroup END
endif
augroup plugin-clever-f-finalizer
    autocmd!
augroup END

# initialize the internal state
var last_mode: string
var previous_map: dict<string>
var previous_pos: dict<list<number>>
var first_move: dict<number>
var migemo_dicts: dict<dict<string>>
var previous_char_num: dict<any>
var timestamp: list<number> = [0, 0]
var highlight_timer: number = -1

# keys are mode string returned from mode()
def clever_f#reset(): string
    previous_map = {}
    previous_pos = {}
    first_move = {}
    migemo_dicts = {}

    # Note:
    # [0, 0] may be invalid because the representation of return value of reltime() depends on implementation.
    timestamp = [0, 0]

    RemoveHighlight()

    return ''
enddef

# hidden API for debug
def clever_f#_reset_all()
    clever_f#reset()
    last_mode = ''
    previous_char_num = {}
    autocmd! plugin-clever-f-finalizer
    moved_forward = 0
enddef

def RemoveHighlight()
    if highlight_timer >= 0
        timer_stop(highlight_timer)
        highlight_timer = -1
    endif
    for h: dict<any> in getmatches()
            ->filter((_, v: dict<any>): bool => v.group == 'CleverFChar')
        matchdelete(h.id)
    endfor
enddef

def IsTimedout(): bool
    var cur: list<number> = reltime()
    var rel: string = reltime(timestamp, cur)->reltimestr()
    var elapsed_ms: number = float2nr(str2float(rel) * 1000.0)
    timestamp = cur
    return elapsed_ms > g:clever_f_timeout_ms
enddef

def OnHighlightTimerExpired(timer: number)
    if highlight_timer != timer
        return
    endif
    highlight_timer = -1
    RemoveHighlight()
enddef

# highlight characters to which the cursor can be moved directly
# Note: public function for test
def clever_f#_mark_direct(
    forward: bool,
    count: number
): list<number>

    var line: string = getline('.')
    var l: number
    var c: number
    [_, l, c, _] = getpos('.')

    if (forward && c >= len(line)) || (!forward && c == 1)
        # there is no matching characters
        return []
    endif

    if g:clever_f_ignore_case
        line = line->tolower()
    endif

    var char_count: dict<number>
    var matches: list<number>
    var indices: list<number> = forward ? range(c, len(line) - 1, 1) : range(c - 2, 0, -1)
    for i: number in indices
        var ch: string = line->strpart(i, 1)

        # only matches to ASCII
        if ch !~ '^[\x00-\x7F]$'
            continue
        endif

        var ch_lower: string = ch->tolower()

        char_count[ch] = get(char_count, ch, 0) + 1
        if g:clever_f_smart_case && ch =~ '\u'
            # uppercase characters are doubly counted
            char_count[ch_lower] = get(char_count, ch_lower, 0) + 1
        endif

        if char_count[ch] == count ||
              (g:clever_f_smart_case && char_count[ch_lower] == count)
            # NOTE: should not use `matchaddpos(group, [...position])`,
            # because the maximum number of position is 8
            var m: number = matchaddpos('CleverFDirect', [[l, i + 1]])
            matches->add(m)
        endif
    endfor

    return matches
enddef

def MarkCharInCurrentLine(map: string, char: any)
    var regex: string  = '\%' .. line('.') .. 'l' .. GeneratePattern(map, char)
    matchadd('CleverFChar', regex, 999)
enddef

# Note:
# \x80\xfd` seems to be sent by a terminal.
# Below is a workaround for the sequence.
def Getchar(): any
    while true
        var cn: any = getchar()
        if type(cn) != type('') || cn != "\x80\xfd`"
            return cn
        endif
    endwhile
    return 0
enddef

def IncludeMultibyteChar(str: string): bool
    return strlen(str) != clever_f#compat#strchars(str)
enddef

def clever_f#find_with(map: string): string
    if map !~ '^[fFtT]$'
        throw "clever-f: Invalid mapping '" .. map .. "'"
    endif

    if &foldopen =~ '\<\%(all\|hor\)\>'
        while foldclosed('.') >= 0
            foldopen
        endwhile
    endif

    var current_pos: list<number> = getpos('.')[1 : 2]
    var mode: string = Mode()
    var highlight_timer_enabled: bool = g:clever_f_mark_char
        && g:clever_f_highlight_timeout_ms > 0
        && HAS_TIMER
    var in_macro: bool = clever_f#compat#reg_executing() != ''

    var back: bool
    # When 'f' is run while executing a macro, do not repeat previous
    # character. See #59 for more details
    if current_pos != get(previous_pos, mode, [0, 0]) || in_macro
        var should_redraw: bool = !in_macro
        var cursor_marker: number
        if g:clever_f_mark_cursor
            cursor_marker = matchadd('CleverFCursor', '\%#', 999)
            if should_redraw
                redraw
            endif
        endif
        # block-NONE does not work on Neovim
        var guicursor_save: string
        var t_ve_save: string
        if g:clever_f_hide_cursor_on_cmdline && !s:ON_NVIM
            guicursor_save = &guicursor
            set guicursor=n-o:block-NONE
            t_ve_save = &t_ve
            set t_ve=
        endif
        var direct_markers: list<number>
        try
            if g:clever_f_mark_direct && should_redraw
                direct_markers = clever_f#_mark_direct(map =~ '\l', v:count1)
                redraw
            endif
            if g:clever_f_show_prompt
                echon 'clever-f: '
            endif
            previous_map[mode] = map
            first_move[mode] = 1
            var cn: any = Getchar()
            if cn->typename() == 'number' && cn == ESC_CODE
                return "\<Esc>"
            endif
            if g:clever_f_repeat_last_char_inputs
                ->deepcopy()
                ->mapnew((_, v: string): number => char2nr(v))
                ->index(cn) == -1
                previous_char_num[mode] = cn
            else
                if previous_char_num->has_key(last_mode)
                    previous_char_num[mode] = previous_char_num[last_mode]
                else
                    echohl ErrorMsg | echo 'Previous input not found.' | echohl None
                    return ''
                endif
            endif
            last_mode = mode

            if g:clever_f_timeout_ms > 0
                timestamp = reltime()
            endif

            if g:clever_f_mark_char
                RemoveHighlight()
                if mode == 'n' || mode ==? 'v' || mode == "\<C-v>" ||
                   mode == 'ce' || mode ==? 's' || mode == "\<C-s>"
                    augroup plugin-clever-f-finalizer
                        autocmd CursorMoved <buffer> MaybeFinalize()
                        autocmd InsertEnter <buffer> Finalize()
                    augroup END
                    MarkCharInCurrentLine(previous_map[mode], previous_char_num[mode])
                endif
            endif

            if g:clever_f_show_prompt && should_redraw
                redraw!
            endif
        finally
            if g:clever_f_mark_cursor
                matchdelete(cursor_marker)
            endif
            if g:clever_f_mark_direct && !direct_markers->empty()
                for m: number in direct_markers
                    matchdelete(m)
                endfor
            endif
            if g:clever_f_hide_cursor_on_cmdline && !ON_NVIM
                # Set default value at first then restore (#49)
                # For example, when the value is a:blinkon0, it does not affect cursor shape so cursor
                # shape continues to disappear.
                set guicursor&

                if &guicursor != guicursor_save
                    &guicursor = guicursor_save
                endif
                &t_ve = t_ve_save
            endif
        endtry
    else
        # When repeated

        back = map =~ '\u'
        if g:clever_f_fix_key_direction && previous_map[mode] =~ '\u'
            back = !back
        endif

        # reset and retry if timed out
        if g:clever_f_timeout_ms > 0 && IsTimedout()
            clever_f#reset()
            return clever_f#find_with(map)
        endif

        # Restore highlights which were removed by timeout
        if highlight_timer_enabled && highlight_timer < 0
            RemoveHighlight()
            if mode == 'n' || mode ==? 'v' || mode == "\<C-v>" ||
               mode == 'ce' || mode ==? 's' || mode == "\<C-s>"
                MarkCharInCurrentLine(previous_map[mode], previous_char_num[mode])
            endif
        endif
    endif

    if highlight_timer_enabled
        if highlight_timer >= 0
            timer_stop(highlight_timer)
        endif
        highlight_timer = timer_start(g:clever_f_highlight_timeout_ms, OnHighlightTimerExpired)
    endif

    return clever_f#repeat(back)
enddef

def clever_f#repeat(back: bool): string
    var mode: string = Mode()
    var pmap: string = get(previous_map, mode, '')
    var prev_char_num: any = get(previous_char_num, mode, 0)

    if pmap == ''
        return ''
    endif

    # ignore special characters like \<Left>
    if type(prev_char_num) == type('') && char2nr(prev_char_num) == 128
        return ''
    endif

    if back
        pmap = Swapcase(pmap)
    endif

    var cmd: string
    if mode[0] ==? 'v' || mode[0] == "\<C-v>"
        cmd = MoveCmdForVisualmode(pmap, prev_char_num)
    else
        var inclusive: bool = mode == 'no' && pmap =~ '\l'
        cmd = printf("%s:\<C-u>call clever_f#find(%s, %s)\<CR>",
                     inclusive ? 'v' : '',
                     string(pmap), prev_char_num)
    endif

    return cmd
enddef

# absolutely moved forward?
def MovesForward(
    p: list<number>,
    n: list<number>
): number

    if p[0] != n[0]
        return p[0] < n[0] ? 1 : 0
    endif

    if p[1] != n[1]
        return p[1] < n[1] ? 1 : 0
    endif

    return 0
enddef

def clever_f#find(map: string, char_num: number)
    var before_pos: list<number> = getpos('.')[1 : 2]
    var next_pos: list<number> = NextPos(map, char_num, v:count1)
    if next_pos == [0, 0]
        return
    endif

    var moves_forward: number = MovesForward(before_pos, next_pos)

    # update highlight when cursor moves across lines
    var mode: string = Mode()
    if g:clever_f_mark_char
        if next_pos[0] != before_pos[0]
            || (map ==? 't' && !first_move[mode] && clever_f#compat#xor(moved_forward, moves_forward))
            RemoveHighlight()
            MarkCharInCurrentLine(map, char_num)
        endif
    endif

    moved_forward = moves_forward
    previous_pos[mode] = next_pos
    first_move[mode] = 0
enddef

def Finalize()
    autocmd! plugin-clever-f-finalizer
    RemoveHighlight()
    previous_pos = {}
    moved_forward = 0
enddef

def MaybeFinalize()
    var pp: list<number> = get(previous_pos, last_mode, [0, 0])
    if getpos('.')[1 : 2] != pp
        Finalize()
    endif
enddef

def MoveCmdForVisualmode(
    map: string,
    char_num: number
): string

    var next_pos: list<number> = NextPos(map, char_num, v:count1)
    if next_pos == [0, 0]
        return ''
    endif

    var m = Mode()
    setpos("''", [0] + next_pos + [0])
    previous_pos[m] = next_pos
    first_move[m] = 0

    return '``'
enddef

def Search(
    pat: string,
    flag: string
): number

    if g:clever_f_across_no_line
        return search(pat, flag, line('.'))
    else
        return search(pat, flag)
    endif
enddef

def ShouldUseMigemo(char: string): bool
    if !g:clever_f_use_migemo || char !~ '^\a$'
        return false
    endif

    if !g:clever_f_across_no_line
        return true
    endif

    return getline('.')->IncludeMultibyteChar()
enddef

def LoadMigemoDict(): dict<string>
    var enc: string = &l:encoding
    if enc == 'utf-8'
        return clever_f#migemo#utf8#load_dict()
    elseif enc == 'cp932'
        return clever_f#migemo#cp932#load_dict()
    elseif enc == 'euc-jp'
        return clever_f#migemo#eucjp#load_dict()
    else
        g:clever_f_use_migemo = 0
        throw "clever-f: Encoding '" .. enc .. "' is not supported. Migemo is disabled"
    endif
    return {}
enddef

def GeneratePattern(
    map: string,
    char_num: any
): string

    var char: string = type(char_num) == type(0) ? nr2char(char_num) : char_num
    var regex: string = char

    var should_use_migemo: bool = ShouldUseMigemo(char)
    if should_use_migemo
        if !has_key(migemo_dicts, &l:encoding)
            migemo_dicts[&l:encoding] = LoadMigemoDict()
        endif
        regex = migemo_dicts[&l:encoding][regex] .. '\&\%(' .. char .. '\|\A\)'
    elseif stridx(g:clever_f_chars_match_any_signs, char) != -1
        regex = '\[!"#$%&''()=~|\-^\\@`[\]{};:+*<>,.?_/]'
    elseif char == '\'
        regex = '\\'
    endif

    var is_exclusive_visual: bool = &selection == 'exclusive' && Mode()[0] ==? 'v'
    if map == 't' && !is_exclusive_visual
        regex = '\_.\ze\%(' .. regex .. '\)'
    elseif is_exclusive_visual && map == 'f'
        regex = '\%(' .. regex .. '\)\zs\_.'
    elseif map == 'T'
        regex = '\%(' .. regex .. '\)\@<=\_.'
    endif

    if !should_use_migemo
        regex = '\V' .. regex
    endif

    return ((g:clever_f_smart_case && char =~ '\l') || g:clever_f_ignore_case ? '\c' : '\C') .. regex
enddef

def NextPos(
    map: string,
    char_num: number,
    count: number
): list<number>

    var mode: string = Mode()
    var search_flag: string = map =~ '\l' ? 'W' : 'bW'
    var cnt: number = count
    var pattern: string = GeneratePattern(map, char_num)

    if map ==? 't' && get(first_move, mode, 1)
        if !Search(pattern, search_flag .. 'c')
            return [0, 0]
        endif
        --cnt
    endif

    while 0 < cnt
        if !Search(pattern, search_flag)
            return [0, 0]
        endif
        --cnt
    endwhile

    return getpos('.')[1 : 2]
enddef

def Swapcase(char: string): string
    return char =~ '\u' ? tolower(char) : toupper(char)
enddef

# Drop forced visual mode character ('nov' -> 'no')
def Mode(): string
    var mode: string = mode(1)
    if mode =~ '^no'
        mode = mode[0 : 1]
    endif
    return mode
enddef
