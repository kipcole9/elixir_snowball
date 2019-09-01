defmodule Snowball.Combinators do

  # <letter>        ::= a || b || ... || z || A || B || ... || Z
  # <digit>         ::= 0 || 1 || ... || 9
  # <name>          ::= <letter> [ <letter> || <digit> || _ ]*
  # <s_name>        ::= <name>
  # <i_name>        ::= <name>
  # <b_name>        ::= <name>
  # <r_name>        ::= <name>
  # <g_name>        ::= <name>
  # <literal string>::= '[<char>]*'
  # <number>        ::= <digit> [ <digit> ]*
  #
  # S               ::= <s_name> || <literal string>
  # G               ::= <g_name> || <literal string>
  #
  # <declaration>   ::= strings ( [<s_name>]* ) ||
  #                     integers ( [<i_name>]* ) ||
  #                     booleans ( [<b_name>]* ) ||
  #                     routines ( [<r_name>]* ) ||
  #                     externals ( [<r_name>]* ) ||
  #                     groupings ( [<g_name>]* )
  #
  # <r_definition>  ::= define <r_name> as C
  # <plus_or_minus> ::= + || -
  # <g_definition>  ::= define <g_name> G [ <plus_or_minus> G ]*
  #
  # AE              ::= (AE) ||
  #                     AE + AE || AE - AE || AE * AE || AE / AE || - AE ||
  #                     maxint || minint || cursor || limit ||
  #                     size || sizeof <s_name> ||
  #                     len || lenof <s_name> ||
  #                     <i_name> || <number>
  #
  # <i_assign>      ::= $ <i_name> = AE ||
  #                     $ <i_name> += AE || $ <i_name> -= AE ||
  #                     $ <i_name> *= AE || $ <i_name> /= AE
  #
  # <i_test_op>     ::= == || != || > || >= || < || <=
  #
  # <i_test>        ::= $ ( AE <i_test_op> AE ) ||
  #                     $ <i_name> <i_test_op> AE
  #
  # <s_command>     ::= $ <s_name> C
  #
  # C               ::= ( [C]* ) ||
  #                     <i_assign> || <i_test> || <s_command> || C or C || C and C ||
  #                     not C || test C || try C || do C || fail C ||
  #                     goto C || gopast C || repeat C || loop AE C ||
  #                     atleast AE C || S || = S || insert S || attach S ||
  #                     <- S || delete ||  hop AE || next ||
  #                     => <s_name> || [ || ] || -> <s_name> ||
  #                     setmark <i_name> || tomark AE || atmark AE ||
  #                     tolimit || atlimit || setlimit C for C ||
  #                     backwards C || reverse C || substring ||
  #                     among ( [<literal string> [<r_name>] || (C)]* ) ||
  #                     set <b_name> || unset <b_name> || <b_name> ||
  #                     <r_name> || <g_name> || non [-] <g_name> ||
  #                     true || false || ?
  #
  # P              ::=  [P]* || <declaration> ||
  #                     <r_definition> || <g_definition> ||
  #                     backwardmode ( P )
  #
  # <program>      ::=  P
  #
  #
  #
  # synonyms:      <+ for insert

end