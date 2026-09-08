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
%define S_D_HOME     28         ; "Latest posts from "
%define S_D_TAG      29         ; "Posts tagged #"
%define S_D_ON       30         ; " on "
%define S_T_PAGE     31         ; " · page "
%define S_T_SEARCHQ  32         ; "search: "
%define S_N_SAVED    33         ; dashboard notices after a redirect
%define S_N_DRAFT    34
%define S_N_DELETED  35
%define S_N_SETTINGS 36
%define S_T_MEDIA    37         ; "media" (the library page title)
%define S_T_MDELETE  38
%define S_N_UPLOADED 39
%define S_N_MDELETED 40
%define S_E_UPTYPE   41         ; upload errors (carry their own wrapper)
%define S_E_UPEMPTY  42
%define S_E_UPCONV   43
%define S_E_UPSTORE  44
%define S_E_UPNOCONV 45
%define S_E_UPFULL   46
%define S_LB_OPEN    47         ; lightbox link labels (aria)
%define S_LB_CLOSE   48
%define S_E_IMGMAX   49         ; settings: image size out of range
