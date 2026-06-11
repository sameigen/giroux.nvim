if exists("b:current_syntax") | finish | endif
syn match girouxStatsTitle /\%1l.*/
syn match girouxStatsHeader /^\(Written\|Read\|Web\|Subagents\|Spend\).*/
syn match girouxStatsAdd /+\d\+/
syn match girouxStatsDel /-\d\+/
hi def link girouxStatsTitle Title
hi def link girouxStatsHeader Statement
hi def link girouxStatsAdd DiagnosticOk
hi def link girouxStatsDel DiagnosticError
let b:current_syntax = "giroux-stats"
