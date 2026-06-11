if exists("b:current_syntax") | finish | endif

syn match girouxRosterHeader /\%1l.*/
syn match girouxRosterWorking /^● .*/ contains=girouxRosterCols
syn match girouxRosterQn /^? .*/
syn match girouxRosterIdle /^○ .*/ contains=girouxRosterCols
syn match girouxRosterDead /^✗ .*/
syn match girouxRosterStale /^\~ .*/

hi def link girouxRosterHeader Comment
hi def link girouxRosterWorking Normal
hi def link girouxRosterQn DiagnosticWarn
hi def link girouxRosterIdle Comment
hi def link girouxRosterDead DiagnosticError
hi def link girouxRosterStale NonText

let b:current_syntax = "giroux-roster"
