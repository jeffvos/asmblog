; i18n.inc — ids for strings emitted from assembly (everything in the
; HTML templates is localized by the per-locale template directories
; instead). i18n_get(id) -> rax = ptr, rdx = len for the active locale.

%define S_T_HOME     0
%define S_T_SEARCH   1
%define S_T_ADMIN    2
%define S_T_LOGIN    3
%define S_T_EDITOR   4
%define S_T_SETTINGS 5
%define S_T_DELETE   6
%define S_T_PREVIEW  7
%define S_PREVDATE   8
%define S_H_TAG      9
%define S_H_SEARCH   10
%define S_EMPTY      11
%define S_NEWER      12
%define S_OLDER      13
%define S_PUB        14
%define S_DRAFT      15
%define S_DEL_LINK   16
%define S_E_WRONG    17
%define S_E_WAIT     18
%define S_E_NOPW     19
%define S_E_TITLE    20
%define S_E_SLUG     21
%define S_E_SLUGDUP  22
%define S_E_TAGS     23
%define S_E_MD       24
%define S_E_SAVE     25
%define S_E_SET      26
%define S_E_PW       27
%define S_COUNT      28
