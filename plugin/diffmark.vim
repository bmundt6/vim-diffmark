" cat a file's contents chunk-by-chunk;
" then we'll diff each chunk in f_in against the corresponding chunk in f_new
function! DiffMarkCatFile(last_line, line, file)
  "FIXME: force &shell=bash so that process substitution is guaranteed to be supported
  if a:last_line == a:line
    return "<(echo '')"
  else
    return "<(sed -n '" . a:last_line . "," . (a:line - 1) . "p' " . a:file . "; echo '')"
  endif
endfunction

function! DiffMarkImpl()
  let opt = "-a --binary "
  if &diffopt =~ "icase"
    let opt = opt . "-i "
  endif
  if &diffopt =~ "iwhite"
    let opt = opt . "-b "
  endif

  let md5sum_in = system("cat ". v:fname_in . " | md5sum")
  let md5sum_new = system("cat ". v:fname_new . " | md5sum")
  let f_in = v:fname_in
  let f_new = v:fname_new
  let marks_in = get(g:diffmarks, md5sum_in, [])
  let marks_new = get(g:diffmarks, md5sum_new, [])
  if marks_in != [] && marks_new != []
    let last_nr_in = 0
    let last_nr_new = 0
    let both_marks = []
    "FIXME: no reason to nest these loops
    for mark_in in marks_in
      for mark_new in marks_new
        if mark_in.mark == mark_new.mark
          if mark_in.nr <= last_nr_in
            "TODO throw an error?
            break
          endif
          if mark_new.nr <= last_nr_new
            "TODO throw an error?
            break
          endif
          let last_nr_in = mark_in.nr
          let last_nr_new = mark_new.nr
          call add(both_marks, {"in": mark_in, "new": mark_new})
          break
        endif
      endfor
    endfor
    "TODO: add an option to restrict the diff computation between the earliest and latest marked lines in both files
    "      this would give us an easy way to ignore irrelevant diffs within massive files, e.g:
    "      - mark line 9999 in f_in as 'a', line 10999 as 'b'
    "      - mark line 99999 in f_new as 'a', line 100999 as 'b'
    "      - DiffMark skips f_in lines 1-9998,11000-$ and f_new lines 1-99998,101000-$
    let last_nr_in = 0
    let last_nr_new = 0
    silent execute "!echo '' > " . v:fname_out
    "COMBAK: would it be feasible to run these loop iterations in parallel and combine the results afterward?
    for marks in both_marks
      let linenr_in = marks.in.nr
      let linenr_new = marks.new.nr
      let f_in = DiffMarkCatFile(last_nr_in + 1, linenr_in, v:fname_in)
      let f_new = DiffMarkCatFile(last_nr_new + 1, linenr_new, v:fname_new)
      " evil genius awk hack to match the chunk diff line numbers up with the original file
      "TODO: split the diff operation into a separate shell script so we can do a single execute
      "      (don't want to flash the screen multiple times)
      silent execute "!diff " . opt . f_in . " " . f_new .
            \ " | gawk -v off1=" . last_nr_in . " -v off2=" . last_nr_new . " '".
            \ "{ if (match($0, /^([0-9]+)(,([0-9]+))?([acd])([0-9]+)(,([0-9]+))?/, grp)) {" .
            \ "    range1=\"\"; range2=\"\";" .
            \ "    if (grp[3] \\!= \"\") range1=\",\" grp[3]+off1;" .
            \ "    if (grp[7] \\!= \"\") range2=\",\" grp[7]+off2;" .
            \ "    print  grp[1]+off1 range1 grp[4] grp[5]+off2 range2;" .
            \ "  } else { print }" .
            \ "}' >> " . v:fname_out
      if marks.in.line != marks.new.line
        if g:diffmark_force_align == ""
          echo "DiffMark Warning: marked lines are not equal, alignment may not work"
          "echo marks.in
          "echo marks.new
          echo "  Press (f) to force alignment. Diff will not show for marked lines."
          if nr2char(getchar()) ==? "f"
            let g:diffmark_force_align = "force"
          else
            let g:diffmark_force_align = "diff"
          endif
        endif
        if g:diffmark_force_align == "diff"
          silent execute "!echo '" . linenr_in . "c" . linenr_new . "' >> " . v:fname_out
        endif
      endif
      let last_nr_in = linenr_in
      let last_nr_new = linenr_new
    endfor
  else
    silent execute "!diff " . opt . f_in . " " . f_new . " > " . v:fname_out
  endif
endfunction

function! DiffMarkGather(mark_names)
  if &diff
    let marks = []
    for mark in a:mark_names
      let nr = line("'" . mark)
      if nr == 0 || nr > line('$')
        "TODO throw an error
        continue
      endif
      call add(marks, {"mark": mark, "nr": nr, "line": getline(nr)})
    endfor
    if len(marks) == 0
      return
    endif
    call add(marks, {"mark": "EOF", "nr": line('$') + 1, "line": ""})
    let tmp = tempname()
    execute "write! " . tmp
    let md5sum = system("cat ". tmp . " | md5sum")
    call delete(tmp)
    call extend(g:diffmarks, {l:md5sum : marks})
  endif
endfunction

function! s:DiffMark(mark_args)
  let diffexpr_save = &diffexpr
  set diffexpr=DiffMarkImpl()
  let g:diffmark_force_align = ""
  let g:diffmarks = {}
  let mark_names = []
  if len(a:mark_args) > 0
    let mark_names = deepcopy(a:mark_args)
    "TODO print an error message when an invalid mark is specified
    call filter(mark_names, 'len(v:val) == 1')
  endif
  "COMBAK: could we just assume that all lowercase marks are meant for anchoring?
  "TODO: add a config variable to set the default mark names (or use all marks)
  if len(mark_names) == 0
    let mark_names = ['a']
  endif
  let orig_win = winnr()
  windo call DiffMarkGather(mark_names)
  execute orig_win . "wincmd w"
  diffupdate
  let &diffexpr = diffexpr_save
  redraw!
endfunction

function! s:DiffSelf(mark_args)
  let mark_names_real = []
  let mark_names_diff = []

  let apply_to_real = 1
  for arg_mark in a:mark_args
    if len(arg_mark) != 1
      "TODO print an error message when an invalid mark is specified
      continue
    endif
    if arg_mark == ","
      let apply_to_real = 0
      continue
    endif
    if apply_to_real
      call add(mark_names_real, arg_mark)
    else
      call add(mark_names_diff, arg_mark)
    endif
  endfor
  if len(mark_names_real) == 0
    let mark_names_real = ['a', 'b']
  endif
  if len(mark_names_diff) == 0
    let mark_names_diff = ['c', 'd']
  endif
  if len(mark_names_real) > len(mark_names_diff)
    let mark_names_real = mark_names_real[0:len(mark_names_diff) - 1]
  endif
  if len(mark_names_diff) > len(mark_names_real)
    let mark_names_diff = mark_names_diff[0:len(mark_names_real) - 1]
  endif

  let g:diffmarks = {}
  diffthis
  call DiffMarkGather(mark_names_diff)

  let filetype = &ft
  let lines = getline(1, "$")
  vnew
  "FIXME: remove the spare line at the beginning
  "       could we just use :sav for all this?
  call append("$", lines)
  exe "setlocal bt=nofile bh=wipe nobl noswf ro ft=" . filetype
  exe "file " . expand("#") . ".DiffSelf"
  let mark_index = 0
  for marks in values(g:diffmarks)
    for mark in marks
      if mark.mark == "EOF"
        break
      endif
      exe "keepjumps normal " . (mark.nr + 1) . "ggm" . mark_names_real[mark_index]
      let mark_index += 1
    endfor
  endfor

  diffthis
  call s:DiffMark(mark_names_real)
endfunction

" func! s:MyRange(r, ...) range
"   echo "MyRange ". a:firstline . " " . a:lastline. " " . a:r
"   echo "0 " . a:0
"   echo "1 " . a:1
" endfunction
" com! -range MyRange <line1>,<line2>call s:MyRange(<range>, "help", 5)

" update the active vimdiff windows so that the lines marked 'a' in each file are aligned
" or, pass custom marks to use for alignment as follows:
" :DiffMark a b c
com! -narg=* DiffMark call s:DiffMark([<f-args>])
" open a new temp file to compare 'a,'b to 'c,'d within the current buffer
" or, pass custom region arguments as follows:
" :DiffSelf a b , c d
"TODO maybe change this for consistency with Vim syntax like so:
" :DiffSelf 'a,'b 'c,'d
com! -narg=* DiffSelf call s:DiffSelf([<f-args>])
