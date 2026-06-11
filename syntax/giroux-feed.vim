if exists("b:current_syntax") | finish | endif

syn match girouxFeedDim /^  │.*/
syn match girouxFeedQueued /^queued: .*/
syn match girouxFeedTurn /^── .*──$/
syn match girouxFeedTurn /^═══ .*═══$/
syn match girouxFeedTurn /^┄┄ .*┄┄$/
syn match girouxFeedTurn /^-- interrupted --$/
syn match girouxFeedErr /^ERR .*/
syn match girouxFeedQn /^? .*/
syn match girouxFeedQnOpt /^    \d\+\. .*/
syn match girouxFeedHead /^[▸▾] .*/ contains=girouxFeedTool,girouxFeedStatus
syn match girouxFeedTool /^[▸▾] [a-z]\+/ contained
syn match girouxFeedStatus /  [+0-9.s -]*\(ok\|err\)$/ contained contains=girouxFeedOk,girouxFeedBad
syn match girouxFeedOk /ok$/ contained
syn match girouxFeedBad /err$/ contained

hi def link girouxFeedDim Comment
hi def link girouxFeedQueued Comment
hi def link girouxFeedTurn Comment
hi def link girouxFeedErr DiagnosticError
hi def link girouxFeedQn DiagnosticWarn
hi def link girouxFeedQnOpt Normal
hi def link girouxFeedHead Statement
hi def link girouxFeedTool Special
hi def link girouxFeedStatus Comment
hi def link girouxFeedOk DiagnosticOk
hi def link girouxFeedBad DiagnosticError

let b:current_syntax = "giroux-feed"
