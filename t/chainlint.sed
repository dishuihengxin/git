#------------------------------------------------------------------------------
# Detect broken &&-chains in tests.
#
# At present, only &&-chains in subshells are examined by this linter;
# top-level &&-chains are instead checked directly by the test framework. Like
# the top-level &&-chain linter, the subshell linter (intentionally) does not
# check &&-chains within {...} blocks.
#
# Checking for &&-chain breakage is done line-by-line by pure textual
# inspection.
#
# Incomplete lines (those ending with "\") are stitched together with following
# lines to simplify processing, particularly of "one-liner" statements.
# Top-level here-docs are swallowed to avoid false positives within the
# here-doc body, although the statement to which the here-doc is attached is
# retained.
#
# Heuristics are used to detect end-of-subshell when the closing ")" is cuddled
# with the final subshell statement on the same line:
#
#    (cd foo &&
#        bar)
#
# in order to avoid misinterpreting the ")" in constructs such as "x=$(...)"
# and "case $x in *)" as ending the subshell.
#
# Lines missing a final "&&" are flagged with "?!AMP?!", and lines which chain
# commands with ";" internally rather than "&&" are flagged "?!SEMI?!". A line
# may be flagged for both violations.
#
# Detection of a missing &&-link in a multi-line subshell is complicated by the
# fact that the last statement before the closing ")" must not end with "&&".
# Since processing is line-by-line, it is not known whether a missing "&&" is
# legitimate or not until the _next_ line is seen. To accommodate this, within
# multi-line subshells, each line is stored in sed's "hold" area until after
# the next line is seen and processed. If the next line is a stand-alone ")",
# then a missing "&&" on the previous line is legitimate; otherwise a missing
# "&&" is a break in the &&-chain.
#
#    (
#         cd foo &&
#         bar
#    )
#
# In practical terms, when "bar" is encountered, it is flagged with "?!AMP?!",
# but when the stand-alone ")" line is seen which closes the subshell, the
# "?!AMP?!" violation is removed from the "bar" line (retrieved from the "hold"
# area) since the final statement of a subshell must not end with "&&". The
# final line of a subshell may still break the &&-chain by using ";" internally
# to chain commands together rather than "&&", so "?!SEMI?!" is never removed
# from a line (even though "?!AMP?!" might be).
#
# Care is taken to recognize the last _statement_ of a multi-line subshell, not
# necessarily the last textual _line_ within the subshell, since &&-chaining
# applies to statements, not to lines. Consequently, blank lines, comment
# lines, and here-docs are swallowed (but not the command to which the here-doc
# is attached), leaving the last statement in the "hold" area, not the last
# line, thus simplifying &&-link checking.
#
# The final statement before "done" in for- and while-loops, and before "elif",
# "else", and "fi" in if-then-else likewise must not end with "&&", thus
# receives similar treatment.
#
# To facilitate regression testing (and manual debugging), a ">" annotation is
# applied to the line containing ")" which closes a subshell, ">>" to a line
# closing a nested subshell, and ">>>" to a line closing both at once. This
# makes it easy to detect whether the heuristics correctly identify
# end-of-subshell.
#------------------------------------------------------------------------------

# incomplete line -- slurp up next line
:squash
/\\$/ {
      N
      s/\\\n//
      bsquash
}

# here-doc -- swallow it to avoid false hits within its body (but keep the
# command to which it was attached)
/<<[ 	]*[-\\]*EOF[ 	]*/ {
	s/[ 	]*<<[ 	]*[-\\]*EOF//
	h
	:hereslurp
	N
	s/.*\n//
	/^[ 	]*EOF[ 	]*$/!bhereslurp
	x
}

# one-liner "(...) &&"
/^[ 	]*!*[ 	]*(..*)[ 	]*&&[ 	]*$/boneline

# same as above but without trailing "&&"
/^[ 	]*!*[ 	]*(..*)[ 	]*$/boneline

# one-liner "(...) >x" (or "2>x" or "<x" or "|x" or "&"
/^[ 	]*!*[ 	]*(..*)[ 	]*[0-9]*[<>|&]/boneline

# multi-line "(...\n...)"
/^[ 	]*(/bsubshell

# innocuous line -- print it and advance to next line
b

# found one-liner "(...)" -- mark suspect if it uses ";" internally rather than
# "&&" (but not ";" in a string)
:oneline
/;/{
	/"[^"]*;[^"]*"/!s/^/?!SEMI?!/
}
b

:subshell
# bare "(" line?
/^[ 	]*([	]*$/ {
	# stash for later printing
	h
	bnextline
}
# "(..." line -- split off and stash "(", then process "..." as its own line
x
s/.*/(/
x
s/(//
bslurp

:nextline
N
s/.*\n//

:slurp
# incomplete line "...\"
/\\$/bincomplete
# multi-line quoted string "...\n..."
/^[^"]*"[^"]*$/bdqstring
# multi-line quoted string '...\n...' (but not contraction in string "it's so")
/^[^']*'[^']*$/{
	/"[^'"]*'[^'"]*"/!bsqstring
}
# here-doc -- swallow it
/<<[ 	]*[-\\]*EOF/bheredoc
/<<[ 	]*[-\\]*EOT/bheredoc
/<<[ 	]*[-\\]*INPUT_END/bheredoc
# comment or empty line -- discard since final non-comment, non-empty line
# before closing ")", "done", "elsif", "else", or "fi" will need to be
# re-visited to drop "suspect" marking since final line of those constructs
# legitimately lacks "&&", so "suspect" mark must be removed
/^[ 	]*#/bnextline
/^[ 	]*$/bnextline
# in-line comment -- strip it (but not "#" in a string, Bash ${#...} array
# length, or Perforce "//depot/path#42" revision in filespec)
/[ 	]#/{
	/"[^"]*#[^"]*"/!s/[ 	]#.*$//
}
# one-liner "case ... esac"
/^[ 	]*case[ 	]*..*esac/bcheckchain
# multi-line "case ... esac"
/^[ 	]*case[ 	]..*[ 	]in/bcase
# multi-line "for ... done" or "while ... done"
/^[ 	]*for[ 	]..*[ 	]in/bcontinue
/^[ 	]*while[ 	]/bcontinue
/^[ 	]*do[ 	]/bcontinue
/^[ 	]*do[ 	]*$/bcontinue
/;[ 	]*do/bcontinue
/^[ 	]*done[ 	]*&&[ 	]*$/bdone
/^[ 	]*done[ 	]*$/bdone
/^[ 	]*done[ 	]*[<>|]/bdone
/^[ 	]*done[ 	]*)/bdone
/||[ 	]*exit[ 	]/bcontinue
/||[ 	]*exit[ 	]*$/bcontinue
# multi-line "if...elsif...else...fi"
/^[ 	]*if[ 	]/bcontinue
/^[ 	]*then[ 	]/bcontinue
/^[ 	]*then[ 	]*$/bcontinue
/;[ 	]*then/bcontinue
/^[ 	]*elif[ 	]/belse
/^[ 	]*elif[ 	]*$/belse
/^[ 	]*else[ 	]/belse
/^[ 	]*else[ 	]*$/belse
/^[ 	]*fi[ 	]*&&[ 	]*$/bdone
/^[ 	]*fi[ 	]*$/bdone
/^[ 	]*fi[ 	]*[<>|]/bdone
/^[ 	]*fi[ 	]*)/bdone
# nested one-liner "(...) &&"
/^[ 	]*(.*)[ 	]*&&[ 	]*$/bcheckchain
# nested one-liner "(...)"
/^[ 	]*(.*)[ 	]*$/bcheckchain
# nested one-liner "(...) >x" (or "2>x" or "<x" or "|x")
/^[ 	]*(.*)[ 	]*[0-9]*[<>|]/bcheckchain
# nested multi-line "(...\n...)"
/^[ 	]*(/bnest
# multi-line "{...\n...}"
/^[ 	]*{/bblock
# closing ")" on own line -- exit subshell
/^[ 	]*)/bclosesolo
# "$((...))" -- arithmetic expansion; not closing ")"
/\$(([^)][^)]*))[^)]*$/bcheckchain
# "$(...)" -- command substitution; not closing ")"
/\$([^)][^)]*)[^)]*$/bcheckchain
# multi-line "$(...\n...)" -- command substitution; treat as nested subshell
/\$([ 	     ]*$/bnest
# "=(...)" -- Bash array assignment; not closing ")"
/=(/bcheckchain
# closing "...) &&"
/)[ 	]*&&[ 	]*$/bclose
# closing "...)"
/)[ 	]*$/bclose
# closing "...) >x" (or "2>x" or "<x" or "|x")
/)[ 	]*[<>|]/bclose
:checkchain
# mark suspect if line uses ";" internally rather than "&&" (but not ";" in a
# string and not ";;" in one-liner "case...esac")
/;/{
	/;;/!{
		/"[^"]*;[^"]*"/!s/^/?!SEMI?!/
	}
}
# line ends with pipe "...|" -- valid; not missing "&&"
/|[ 	]*$/bcontinue
# missing end-of-line "&&" -- mark suspect
/&&[ 	]*$/!s/^/?!AMP?!/
:continue
# retrieve and print previous line
x
n
bslurp

# found incomplete line "...\" -- slurp up next line
:incomplete
N
s/\\\n//
bslurp

# found multi-line double-quoted string "...\n..." -- slurp until end of string
:dqstring
s/"//g
N
s/\n//
/"/!bdqstring
bcheckchain

# found multi-line single-quoted string '...\n...' -- slurp until end of string
:sqstring
s/'//g
N
s/\n//
/'/!bsqstring
bcheckchain

# found here-doc -- swallow it to avoid false hits within its body (but keep
# the command to which it was attached); take care to handle here-docs nested
# within here-docs by only recognizing closing tag matching outer here-doc
# opening tag
:heredoc
/EOF/{ s/[ 	]*<<[ 	]*[-\\]*EOF//; s/^/EOF/; }
/EOT/{ s/[ 	]*<<[ 	]*[-\\]*EOT//; s/^/EOT/; }
/INPUT_END/{ s/[ 	]*<<[ 	]*[-\\]*INPUT_END//; s/^/INPUT_END/; }
:hereslurpsub
N
/^EOF.*\n[ 	]*EOF[ 	]*$/bhereclose
/^EOT.*\n[ 	]*EOT[ 	]*$/bhereclose
/^INPUT_END.*\n[ 	]*INPUT_END[ 	]*$/bhereclose
bhereslurpsub
:hereclose
s/^EOF//
s/^EOT//
s/^INPUT_END//
s/\n.*$//
bcheckchain

# found "case ... in" -- pass through untouched
:case
x
n
/^[ 	]*esac/bslurp
bcase

# found "else" or "elif" -- drop "suspect" from final line before "else" since
# that line legitimately lacks "&&"
:else
x
s/?!AMP?!//
x
bcontinue

# found "done" closing for-loop or while-loop, or "fi" closing if-then -- drop
# "suspect" from final contained line since that line legitimately lacks "&&"
:done
x
s/?!AMP?!//
x
# is 'done' or 'fi' cuddled with ")" to close subshell?
/done.*)/bclose
/fi.*)/bclose
bcheckchain

# found nested multi-line "(...\n...)" -- pass through untouched
:nest
x
:nestslurp
n
# closing ")" on own line -- stop nested slurp
/^[ 	]*)/bnestclose
# comment -- not closing ")" if in comment
/^[ 	]*#/bnestcontinue
# "$((...))" -- arithmetic expansion; not closing ")"
/\$(([^)][^)]*))[^)]*$/bnestcontinue
# "$(...)" -- command substitution; not closing ")"
/\$([^)][^)]*)[^)]*$/bnestcontinue
# closing "...)" -- stop nested slurp
/)/bnestclose
:nestcontinue
x
bnestslurp
:nestclose
s/^/>>/
# is it "))" which closes nested and parent subshells?
/)[ 	]*)/bslurp
bcheckchain

# found multi-line "{...\n...}" block -- pass through untouched
:block
x
n
# closing "}" -- stop block slurp
/}/bcheckchain
bblock

# found closing ")" on own line -- drop "suspect" from final line of subshell
# since that line legitimately lacks "&&" and exit subshell loop
:closesolo
x
s/?!AMP?!//
p
x
s/^/>/
b

# found closing "...)" -- exit subshell loop
:close
x
p
x
s/^/>/
b
