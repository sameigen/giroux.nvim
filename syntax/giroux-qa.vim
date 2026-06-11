if exists("b:current_syntax") | finish | endif
syn match girouxQATools /^  ⋯ .*/
syn match girouxQAQ /^? .*/
syn match girouxQAOpt /^    \d\+\. .*/
hi def link girouxQATools Comment
hi def link girouxQAQ DiagnosticWarn
hi def link girouxQAOpt Normal
let b:current_syntax = "giroux-qa"
