"=============================================================================
" File: autoload/ulf/popup.vim
" License: MIT
" Description: popup functions for ULF.
" Origin: Copied and adapted from gitmessenger.vim.
"=============================================================================

let s:popup = {}
let s:floating_window_available = has('nvim') && exists('*nvim_win_set_config')

function! s:popup__close() dict abort
    if !has_key(self, 'bufnr')
        " Already closed
        return
    endif

    let winnr = self.get_winnr()
    if winnr > 0
        " Without this 'noautocmd', the BufWipeout event will be triggered and
        " this function will be called again.
        noautocmd execute winnr . 'wincmd c'
    endif

    unlet self.bufnr
    unlet self.win_id

    if has_key(self.opts, 'did_close')
        call self.opts.did_close(self)
    endif
endfunction
let s:popup.close = funcref('s:popup__close')

function! s:popup__get_winnr() dict abort
    if !has_key(self, 'bufnr')
        return 0
    endif

    " Note: bufwinnr() is not available here because there may be multiple
    " windows which open the buffer. This situation happens when enter <C-w>v
    " in popup window. It opens a new normal window with the popup's buffer.
    return win_id2win(self.win_id)
endfunction
let s:popup.get_winnr = funcref('s:popup__get_winnr')

function! s:popup__scroll(map) dict abort
    let winnr = self.get_winnr()
    if winnr == 0
        return
    endif
    execute winnr . 'wincmd w'
    sandbox let input = eval('"\<'.a:map.'>"')
    execute 'normal!' input
    wincmd p
endfunction
let s:popup.scroll = funcref('s:popup__scroll')

function! s:popup__into() dict abort
    let winnr = self.get_winnr()
    if winnr == 0
        return
    endif
    execute winnr . 'wincmd w'
endfunction
let s:popup.into = funcref('s:popup__into')

function! s:popup__window_size() dict abort
    let has_max_width = exists('g:ulf#popup#max_width') && type(g:ulf#popup#max_width) == v:t_number
    if has_max_width
        " ` - 1` for considering right margin
        let max_width = g:ulf#popup#max_width - self.opts.paddings[0]
    endif

    let width = 0
    let height = 0
    for line in self.contents
        let lw = strdisplaywidth(line)
        if lw > width
            if has_max_width && lw > max_width
                let height += lw / max_width + 1
                let width = max_width
                continue
            endif
            let width = lw
        endif
        let height += 1
    endfor
    " right margin
    let width += self.opts.paddings[0]

    let has_max_height = exists('g:ulf#popup#max_height') && type(g:ulf#popup#max_height) == v:t_number
    if has_max_height && height > g:ulf#popup#max_height
        let height = g:ulf#popup#max_height
    endif

    return [width, height]
endfunction
let s:popup.window_size = funcref('s:popup__window_size')

function! s:popup__floating_win_opts(width, height) dict abort
    if exists('b:__ulf_pmenu_info')
        let pum_height = b:__ulf_pmenu_info.height
        let pum_row = b:__ulf_pmenu_info.row
        let pum_col = b:__ulf_pmenu_info.col
    endif

    let has_space_below = self.opened_at[0] + a:height <= &lines
    let has_space_above = self.opened_at[0] - a:height > 0

    if !self.prefer_top && has_space_below || self.prefer_top && !has_space_above
        let vert = 'N'
        let row = self.opened_at[0]
    else
        let vert = 'S'
        let row = self.opened_at[0] - 1
    endif

    let hor = 'W'

    if self.opened_at[1] + a:width <= &columns
        let col = self.opened_at[1] - 1
    else
        let col = &columns - a:width
    endif

    if pumvisible()
        if pum_row < self.opened_at[0] && vert == 'S'
            let row -= pum_height
        elseif pum_row > self.opened_at[0] && vert == 'N'
            let row += pum_height
        endif
    endif

    return {
    \   'relative': 'editor',
    \   'anchor': vert . hor,
    \   'row': row,
    \   'col': col,
    \   'width': a:width,
    \   'height': a:height,
    \   'style': 'minimal',
    \ }
endfunction
let s:popup.floating_win_opts = funcref('s:popup__floating_win_opts')

function! s:popup__get_opener_winnr() dict abort
    let winnr = win_id2win(self.opener_winid)
    if winnr != 0
        return winnr
    endif
    let winnr = bufwinnr(self.opener_bufnr)
    if winnr > 0
        return winnr
    endif
    return 0
endfunction
let s:popup.get_opener_winnr = funcref('s:popup__get_opener_winnr')

function! s:popup__apply_highlights() dict abort
    let ns_id = nvim_create_namespace('ulf#popup#ns_id')
    call nvim_buf_clear_namespace(self.bufnr, ns_id, 0, -1)
    if has_key(self.opts, 'highlights')
        for highlight in self.opts.highlights
            let [group, line, startcol, endcol] = highlight
            call nvim_buf_add_highlight(self.bufnr, ns_id, group, line, startcol, endcol)
        endfor
    endif
endfunction
let s:popup.apply_highlights = funcref('s:popup__apply_highlights')

function! s:popup__open() dict abort
    let pos = win_screenpos('.')
    let self.opened_at = [pos[0] + winline() - 1, pos[1] + wincol() - 1]
    let self.opener_bufnr = bufnr('%')
    let self.opener_winid = win_getid()
    let self.type = s:floating_window_available ? 'floating' : 'preview'
    let self.prefer_top = get(self.opts, 'prefer_top', v:false)

    let [width, height] = self.window_size()

    " Open window
    if self.type ==# 'floating'
        let opts = self.floating_win_opts(width, height)
        let win_id = nvim_open_win(self.opener_bufnr, v:true, opts)
    else
        let curr_pos = getpos('.')
        let mods = 'noswapfile'
        if exists('g:ulf#popup#preview_mods') && g:ulf#popup#preview_mods !=# ''
            let mods .= ' ' . g:ulf#popup#preview_mods
        endif

        " :pedit! is not available since it refreshes the file buffer (#39)
        execute mods 'new'
        set previewwindow

        call setpos('.', curr_pos)
        wincmd P
        execute height . 'wincmd _'
        let win_id = win_getid()
    endif

    " Setup content
    enew!
    let popup_bufnr = bufnr('%')
    setlocal
    \ buftype=nofile bufhidden=wipe nomodified nobuflisted noswapfile nonumber
    \ nocursorline wrap nonumber norelativenumber signcolumn=no nofoldenable
    \ nospell nolist nomodeline conceallevel=3
    if has_key(self.opts, 'filetype')
        let &l:filetype = self.opts.filetype
    endif
    call setline(1, self.contents)
    setlocal nomodified nomodifiable

    " Setup highlights
    " if has('nvim')
        " setlocal winhighlight=Normal:PopupNormal
    " endif

    if has_key(self.opts, 'mappings')
        for m in keys(self.opts.mappings)
            execute printf('nnoremap <buffer><silent><nowait>%s :<C-u>call b:__ulf_popup.opts.mappings["%s"][0]()<CR>', m, m)
        endfor
        nnoremap <buffer><silent><nowait>? :<C-u>call b:__ulf_popup.echo_help()<CR>
    endif

    " Ensure to close popup
    let b:__ulf_popup = self
    execute 'autocmd BufWipeout,BufLeave <buffer> call getbufvar(' . popup_bufnr . ', "__ulf_popup").close()'

    if has_key(self.opts, 'enter') && !self.opts.enter
        wincmd p
    endif

    let self.bufnr = popup_bufnr
    let self.win_id = win_id

    call self.apply_highlights()
endfunction
let s:popup.open = funcref('s:popup__open')

function! s:popup__update() dict abort
    " Note: `:noautocmd` to prevent BufLeave autocmd event (#13)
    " It should be ok because the cursor position is finally back to the first
    " position.

    let prev_winnr = winnr()

    let popup_winnr = self.get_winnr()
    if popup_winnr == 0
        return
    endif
    let opener_winnr = self.get_opener_winnr()
    if opener_winnr == 0
        return
    endif

    if opener_winnr != prev_winnr
        noautocmd execute opener_winnr . 'wincmd w'
    endif

    try
        let [width, height] = self.window_size()

        " Window must be configured in opener buffer since the window position
        " is relative to cursor
        if self.type ==# 'floating'
            let id = win_getid(popup_winnr)
            if id == 0
                return
            endif
            let opts = self.floating_win_opts(width, height)
            call nvim_win_set_config(id, opts)
        endif

        noautocmd execute popup_winnr . 'wincmd w'

        if self.type ==# 'preview'
            execute height . 'wincmd _'
        endif

        setlocal modifiable
        silent %delete _
        call setline(1, self.contents)
        setlocal nomodified nomodifiable

        call self.apply_highlights()
    finally
        if winnr() != prev_winnr
            noautocmd execute prev_winnr . 'wincmd w'
        endif
    endtry
endfunction
let s:popup.update = funcref('s:popup__update')

function! s:popup__echo_help() dict abort
    if has_key(self.opts, 'mappings')
        let maps = keys(self.opts.mappings)
        call sort(maps, 'i')
        let maps += ['?']

        for map in maps
            if map ==# '?'
                let desc = 'Show this help'
            else
                let desc = self.opts.mappings[map][1]
            endif
            echohl Identifier | echo ' ' . map
            echohl Comment    | echon ' : '
            echohl None       | echon desc
        endfor
    endif
endfunction
let s:popup.echo_help = funcref('s:popup__echo_help')

function! s:popup__pad_content() dict abort
    let [hor, ver] = get(self.opts, 'paddings', [1, 1])
    if empty(self.contents) || self.contents == ['']
        return
    endif

    " Left padding
    call map(self.contents, 'empty(v:val) ? v:val : repeat(" ", hor) . v:val')
    " Top padding
    call extend(self.contents, repeat([''], ver), 0)
    " Bottom padding
    call extend(self.contents, repeat([''], ver))
endfunction
let s:popup.pad_content = funcref('s:popup__pad_content')

" contents: string[] // lines of contents
" opts: {
"   floating?: boolean;
"   bufnr?: number;
"   cursor?: [number, number]; // (line, col)
"   filetype?: string;
"   did_close?: (pupup: Popup) => void;
"   mappings?: {
"     [keyseq: string]: [() => void, string];
"   };
"   enter?: boolean;
"   prefer_top?: boolean;
"   paddings?: [number, number]
" }
function! ulf#popup#new(contents, opts) abort
    let p = deepcopy(s:popup)
    let opts = { 'floating': v:true, 'paddings': [1, 1] }
    call extend(opts, a:opts)
    let p.opts = opts
    let p.contents = a:contents
    call p.pad_content()
    return p
endfunction


" When current window is popup, close the window.
" Returns true when popup window was closed
function! ulf#popup#close_current_popup() abort
    if !exists('b:__ulf_popup')
        return 0
    endif
    call b:__ulf_popup.close()
    " TODO?: Back to opened_at pos by setpos()
    return 1
endfunction
