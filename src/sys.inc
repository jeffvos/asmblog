; sys.inc — Linux x86_64 syscall numbers and kernel ABI constants.
; Syscall convention: nr in rax; args rdi, rsi, rdx, r10, r8, r9.
; The kernel clobbers only rax (return), rcx, r11.

%define SYS_read        0
%define SYS_write       1
%define SYS_open        2
%define SYS_close       3
%define SYS_fstat       5
%define SYS_lseek       8
%define SYS_mmap        9
%define SYS_mprotect    10
%define SYS_munmap      11
%define SYS_ioctl       16
%define SYS_socket      41
%define SYS_sendto      44
%define SYS_bind        49
%define SYS_listen      50
%define SYS_setsockopt  54
%define SYS_clone       56
%define SYS_exit        60      ; exits calling thread only (CLONE_THREAD)
%define SYS_fsync       74
%define SYS_ftruncate   77
%define SYS_rename      82
%define SYS_mkdir       83
%define SYS_time        201
%define SYS_futex       202
%define SYS_clock_gettime 228
%define SYS_sched_getaffinity 204
%define SYS_exit_group  231
%define SYS_epoll_wait  232
%define SYS_epoll_ctl   233
%define SYS_accept4     288
%define SYS_epoll_create1 291
%define SYS_prctl       157
%define SYS_madvise     28
%define SYS_timerfd_create  283
%define SYS_timerfd_settime 286
%define SYS_seccomp     317
%define SYS_getrandom   318

%define PR_SET_NO_NEW_PRIVS 38
%define SECCOMP_SET_MODE_FILTER 1
%define SECCOMP_FILTER_FLAG_TSYNC 1
%define AUDIT_ARCH_X86_64 0xC000003E
%define SECCOMP_RET_ALLOW 0x7fff0000
%define SECCOMP_RET_KILL  0x80000000    ; RET_KILL_PROCESS

%define AF_INET         2
%define SOCK_STREAM     1
%define SOCK_NONBLOCK   0x800
%define SOCK_CLOEXEC    0x80000
%define SOL_SOCKET      1
%define SO_REUSEADDR    2
%define SO_REUSEPORT    15
%define MSG_NOSIGNAL    0x4000      ; suppress SIGPIPE on send to closed peer

%define PROT_NONE       0
%define PROT_READ       1
%define PROT_WRITE      2
%define MAP_SHARED      1
%define MAP_PRIVATE     2
%define MAP_ANONYMOUS   0x20
%define MAP_STACK       0x20000
%define MADV_DONTNEED   4

%define CLOCK_MONOTONIC 1
%define TFD_NONBLOCK    0x800
%define TFD_CLOEXEC     0x80000

%define EAGAIN          11
%define EINTR           4

%define EPOLLIN         1
%define EPOLLOUT        4
%define EPOLLERR        8
%define EPOLLHUP        0x10
%define EPOLL_CTL_ADD   1
%define EPOLL_CTL_DEL   2
%define EPOLL_CTL_MOD   3

%define FUTEX_WAIT_PRIVATE 128
%define FUTEX_WAKE_PRIVATE 129

; CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM
%define CLONE_THREAD_FLAGS 0x50F00

%define O_RDONLY        0
%define O_WRONLY        1
%define O_RDWR          2
%define O_CREAT         0x40
%define O_TRUNC         0x200
%define O_DIRECTORY     0x10000
%define SEEK_SET        0
%define SEEK_END        2

%define TCGETS          0x5401
%define TCSETS          0x5402
%define ECHO_FLAG       8

%define STDIN           0
%define STDOUT          1
%define STDERR          2
