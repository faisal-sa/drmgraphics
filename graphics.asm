; graphics.asm
; A complete example of drawing to the screen using DRM/KMS
; with raw Linux x86-64 syscalls in NASM.
;
; Author: A helpful AI
;
; How to build:
;   nasm -f elf64 graphics.asm -o graphics.o
;   ld graphics.o -o graphics
;
; How to run (IMPORTANT):
;   1. Switch to a Virtual Terminal (VT), e.g., Ctrl+Alt+F3.
;   2. Log in.
;   3. Run with sudo: sudo ./graphics
;   4. Press Enter to exit and restore the screen.

%define BITS 64
section .data

    ; --- System Call Numbers (x86-64) ---
    SYS_READ    equ 0
    SYS_OPEN    equ 2
    SYS_CLOSE   equ 3
    SYS_MMAP    equ 9
    SYS_MUNMAP  equ 11
    SYS_IOCTL   equ 16
    SYS_EXIT    equ 60

    ; --- Constants ---
    O_RDWR      equ 0x2
    PROT_READ   equ 0x1
    PROT_WRITE  equ 0x2
    MAP_SHARED  equ 0x1

    ; --- DRM IOCTL Command Numbers ---
    ; These numbers are derived from /usr/include/drm/drm.h
    ; They are architecture-specific. These are for x86_64.
    DRM_IOCTL_GET_RESOURCES       equ 0xC04864A0
    DRM_IOCTL_GET_CONNECTOR       equ 0xC05064A7
    DRM_IOCTL_GET_ENCODER         equ 0xC01864A6
    DRM_IOCTL_GET_CRTC            equ 0xC02864A1
    DRM_IOCTL_SET_CRTC            equ 0xC05864A2
    DRM_IOCTL_MODE_CREATE_DUMB    equ 0xC02064B2
    DRM_IOCTL_MODE_MAP_DUMB       equ 0xC01064B3
    DRM_IOCTL_MODE_ADDFB          equ 0xC02064B0
    DRM_IOCTL_MODE_RMFB           equ 0xC00464B1
    DRM_IOCTL_MODE_DESTROY_DUMB   equ 0xC00464B4

    ; --- Strings ---
    device_path db "/dev/dri/card0", 0
    msg_ok      db "OK", 10, 0
    msg_err     db "Error", 10, 0
    msg_done    db "Drawing complete. Press Enter to exit...", 10, 0

section .bss
    ; Here we reserve space for all the data structures DRM needs.
    ; This is simpler than stack allocation for a single-threaded app.

    ; --- Variables to store our state ---
    drm_fd      resq 1      ; File descriptor for the DRM device
    screen_ptr  resq 1      ; Pointer to our mmap'd framebuffer memory
    fb_size     resq 1      ; Size of the framebuffer in bytes
    fb_pitch    resd 1      ; Pitch (stride) of the framebuffer
    fb_handle   resd 1      ; Handle for the "dumb buffer"
    fb_id       resd 1      ; ID for the framebuffer object
    connector_id resd 1
    crtc_id     resd 1

    ; --- DRM Structures ---

    ; struct drm_mode_modeinfo
    ; This will hold our selected display mode (resolution, etc.)
    mode_info:
        .clock          resd 1
        .hdisplay       resw 1
        .hsync_start    resw 1
        .hsync_end      resw 1
        .htotal         resw 1
        .hskew          resw 1
        .vdisplay       resw 1
        .vsync_start    resw 1
        .vsync_end      resw 1
        .vtotal         resw 1
        .vscan          resw 1
        .vrefresh       resd 1
        .flags          resd 1
        .type           resd 1
        .name           resb 32

    ; We need to save the original CRTC settings to restore them on exit.
    original_crtc:
        .set_connectors_ptr resq 1
        .count_connectors   resd 1
        .crtc_id            resd 1
        .fb_id              resd 1
        .x                  resd 1
        .y                  resd 1
        .gamma_size         resd 1
        .mode_valid         resd 1
        .mode               resq 1 ; <-- CHANGED: directive is now on the same line
                            ; pointer to a drm_mode_modeinfo struct

    ; struct drm_mode_card_res
    res:
        .fb_id_ptr              resq 1
        .crtc_id_ptr            resq 1
        .connector_id_ptr       resq 1
        .encoder_id_ptr         resq 1
        .count_fbs              resd 1
        .count_crtcs            resd 1
        .count_connectors       resd 1
        .count_encoders         resd 1
        .min_width              resd 1
        .max_width              resd 1
        .min_height             resd 1
        .max_height             resd 1

    ; struct drm_mode_get_connector
    connector:
        .encoders_ptr           resq 1
        .modes_ptr              resq 1
        .props_ptr              resq 1
        .prop_values_ptr        resq 1
        .count_modes            resd 1
        .count_props            resd 1
        .count_encoders         resd 1
        .encoder_id             resd 1
        .connector_id           resd 1
        .connector_type         resd 1
        .connector_type_id      resd 1
        .connection             resd 1
        .mm_width               resd 1
        .mm_height              resd 1
        .subpixel               resd 1
        .pad                    resd 1

    ; Space for the arrays returned by GET_RESOURCES and GET_CONNECTOR
    ; We allocate a fixed size, which is usually sufficient.
    MAX_RESOURCES equ 16
    connector_id_buf resd MAX_RESOURCES
    crtc_id_buf      resd MAX_RESOURCES
    encoder_id_buf   resd MAX_RESOURCES
    mode_info_buf    resb 32 * 1024 ; Generous buffer for mode info structs

    ; A small buffer for the 'read' syscall to wait for user input
    key_buffer resb 1

section .text
global _start

_start:
    ; ================================================
    ; 1. Open DRM Device
    ; ================================================
    mov rax, SYS_OPEN
    mov rdi, device_path
    mov rsi, O_RDWR
    syscall
    test rax, rax
    js _error           ; Jump if rax is negative (error)
    mov [drm_fd], rax

    ; ================================================
    ; 2. Find an active Connector and CRTC
    ; ================================================
    call find_display_configuration
    test rax, rax       ; find_display_configuration returns 0 on success
    jnz _error

    ; ================================================
    ; 3. Save current CRTC state for later restoration
    ; ================================================
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_GET_CRTC
    mov rdx, original_crtc
    mov dword [original_crtc.crtc_id], [crtc_id] ; Tell ioctl which CRTC to get
    syscall
    test rax, rax
    js _error

    ; The GET_CRTC call doesn't fill the mode struct itself, just gives an fb_id
    ; and coordinates. When we restore, we will use our own found mode info
    ; but this ensures we have the original fb_id if needed, though a full
    ; modeset is usually done to restore. For simplicity, we'll re-use our
    ; discovered mode_info struct when restoring.
    mov rax, mode_info
    mov [original_crtc.mode], rax

    ; ================================================
    ; 4. Create Dumb Buffer and Framebuffer
    ; ================================================
    call create_framebuffer
    test rax, rax
    jnz _error

    ; ================================================
    ; 5. Map the dumb buffer into our address space
    ; ================================================
    ; First, get the mmap offset for our dumb buffer
    ; struct drm_mode_map_dumb { handle, pad, offset }
    ; We'll reuse the 'connector' bss space for the struct to avoid stack issues.
    mov dword [connector], [fb_handle] ; Use first 4 bytes for handle
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_MODE_MAP_DUMB
    mov rdx, connector
    syscall
    test rax, rax
    js _error
    ; The offset is returned in the struct at offset 8
    mov r9, [connector + 8] ; The mmap offset goes into r9

    ; Now, perform the mmap
    mov rax, SYS_MMAP
    mov rdi, 0              ; Let kernel choose address
    mov rsi, [fb_size]      ; Length of the mapping
    mov rdx, PROT_READ | PROT_WRITE
    mov r10, MAP_SHARED
    mov r8, [drm_fd]
    ; r9 already has the offset from above
    syscall
    test rax, rax
    js _error
    mov [screen_ptr], rax

    ; ================================================
    ; 6. Set the new mode (perform the modeset)
    ; ================================================
    ; We need to build a drm_mode_crtc struct
    push [connector_id] ; Push our single connector ID onto the stack
    mov r10, rsp        ; r10 points to the connector ID array

    ; struct drm_mode_crtc
    ; { set_connectors_ptr, count_connectors, crtc_id, fb_id, x, y,
    ;   gamma_size, mode_valid, mode }
    ; We'll build this on the stack.
    sub rsp, 64         ; Allocate space for the struct on stack
    mov rdx, rsp        ; rdx points to the struct

    mov [rdx + 0], r10  ; .set_connectors_ptr
    mov dword [rdx + 8], 1 ; .count_connectors
    mov eax, [crtc_id]
    mov [rdx + 12], eax ; .crtc_id
    mov eax, [fb_id]
    mov [rdx + 16], eax ; .fb_id
    mov dword [rdx + 20], 0 ; .x
    mov dword [rdx + 24], 0 ; .y
    mov dword [rdx + 28], 0 ; .gamma_size (0=don't set)
    mov dword [rdx + 32], 1 ; .mode_valid
    mov rax, mode_info
    mov [rdx + 40], rax ; .mode (pointer to our mode_info struct)

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_SET_CRTC
    ; rdx already points to the struct
    syscall

    add rsp, 64 + 8     ; Clean up stack (struct + connector_id)
    test rax, rax
    js _error

    ; ================================================
    ; 7. Draw to the screen!
    ; ================================================
    call draw_gradient

    ; ================================================
    ; 8. Wait for user to press Enter
    ; ================================================
    mov rax, 1          ; write
    mov rdi, 1          ; stdout
    mov rsi, msg_done
    mov rdx, msg_done.len
    syscall

    mov rax, SYS_READ
    mov rdi, 0          ; stdin
    mov rsi, key_buffer
    mov rdx, 1
    syscall

    ; ================================================
    ; 9. Cleanup and exit
    ; ================================================
_cleanup:
    ; Restore the original CRTC settings
    push [connector_id]
    mov r10, rsp
    mov [original_crtc.set_connectors_ptr], r10
    mov dword [original_crtc.count_connectors], 1

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_SET_CRTC
    mov rdx, original_crtc
    syscall
    ; We don't care much about errors here, we're exiting anyway.
    add rsp, 8 ; clean up stack

    ; Unmap the framebuffer
    mov rax, SYS_MUNMAP
    mov rdi, [screen_ptr]
    mov rsi, [fb_size]
    syscall

    ; Destroy the framebuffer object
    ; We'll use the 'connector' bss space again for the struct
    mov dword [connector], [fb_id]
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_RMFB
    mov rdx, connector
    syscall

    ; Destroy the dumb buffer
    mov dword [connector], [fb_handle]
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_MODE_DESTROY_DUMB
    mov rdx, connector
    syscall

    ; Close the DRM device file
    mov rax, SYS_CLOSE
    mov rdi, [drm_fd]
    syscall

_exit:
    mov rax, SYS_EXIT
    xor rdi, rdi        ; Exit code 0
    syscall

_error:
    ; A simple error routine
    mov rax, 1          ; write
    mov rdi, 2          ; stderr
    mov rsi, msg_err
    mov rdx, 6
    syscall
    jmp _exit           ; Exit with code 0 for simplicity

; =========================================================================
; HELPER FUNCTIONS
; =========================================================================

; -------------------------------------------------------------------------
; find_display_configuration
; Populates connector_id, crtc_id, and mode_info.
; Returns: rax=0 on success, rax=1 on failure.
; -------------------------------------------------------------------------
find_display_configuration:
    ; First, get the resource counts and pointers to ID arrays
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_GET_RESOURCES
    mov rdx, res
    ; Setup the pointers in the 'res' struct to our buffers
    mov qword [res.connector_id_ptr], connector_id_buf
    mov qword [res.crtc_id_ptr], crtc_id_buf
    syscall
    test rax, rax
    js .fail

    ; Now, loop through the connectors to find an active one
    mov r12, 0 ; r12 is our loop counter for connectors
.connector_loop:
    cmp r12d, [res.count_connectors]
    jge .fail ; No connected connector found

    ; Get details for the current connector
    mov eax, [connector_id_buf + r12 * 4]
    mov [connector.connector_id], eax

    ; Setup pointers in the 'connector' struct
    mov qword [connector.modes_ptr], mode_info_buf
    mov dword [connector.count_modes], 32 ; Max modes to retrieve
    mov qword [connector.encoders_ptr], encoder_id_buf
    mov dword [connector.count_encoders], MAX_RESOURCES

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_GET_CONNECTOR
    mov rdx, connector
    syscall
    test rax, rax
    js .next_connector

    ; Check if the connector is connected and has modes
    cmp dword [connector.connection], 1
    jne .next_connector
    cmp dword [connector.count_modes], 0
    jle .next_connector

    ; --- Found a good connector! ---
    ; Save its ID
    mov eax, [connector.connector_id]
    mov [connector_id], eax

    ; Save its first mode (usually the preferred one)
    mov rsi, mode_info_buf
    mov rdi, mode_info
    mov rcx, 108 / 8 ; Size of drm_mode_modeinfo is 108 bytes
    rep movsq

    ; Find a CRTC for it. For simplicity, we assume the first CRTC
    ; in the global list can drive our connector. This is usually true
    ; in simple single-head setups. A more robust solution would be
    ; to check the connector's available encoders and find a CRTC
    ; compatible with one of them.
    mov eax, [crtc_id_buf]
    mov [crtc_id], eax

    ; Success!
    xor rax, rax
    ret

.next_connector:
    inc r12
    jmp .connector_loop

.fail:
    mov rax, 1
    ret

; -------------------------------------------------------------------------
; create_framebuffer
; Creates the dumb buffer and the framebuffer object.
; Uses width/height from mode_info.
; Populates fb_handle, fb_pitch, fb_size, fb_id.
; Returns: rax=0 on success, rax=1 on failure.
; -------------------------------------------------------------------------
create_framebuffer:
    ; --- 1. Create a "Dumb Buffer" ---
    ; This is a simple memory buffer for the CPU to draw into.
    ; struct drm_mode_create_dumb { height, width, bpp, flags,
    ;                               handle, pitch, size }
    sub rsp, 32         ; Allocate space for the struct on the stack
    mov rdx, rsp

    movzx eax, word [mode_info.hdisplay]
    mov [rdx + 4], eax  ; width
    movzx eax, word [mode_info.vdisplay]
    mov [rdx + 0], eax  ; height
    mov dword [rdx + 8], 32 ; bpp (bits per pixel)
    mov dword [rdx + 12], 0 ; flags

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_MODE_CREATE_DUMB
    ; rdx already points to our struct
    syscall

    test rax, rax
    js .fail_cleanup_stack

    ; Success, copy results from stack struct to our variables
    mov eax, [rdx + 16]
    mov [fb_handle], eax
    mov eax, [rdx + 20]
    mov [fb_pitch], eax
    mov rax, [rdx + 24] ; size is 64-bit
    mov [fb_size], rax
    add rsp, 32         ; Clean up stack

    ; --- 2. Create a Framebuffer Object from the Dumb Buffer ---
    ; This tells DRM how to interpret the dumb buffer's data.
    ; struct drm_mode_fb_cmd { fb_id, width, height, pitch, bpp,
    ;                          depth, handle }
    sub rsp, 32
    mov rdx, rsp
    movzx eax, word [mode_info.hdisplay]
    mov [rdx + 4], eax  ; width
    movzx eax, word [mode_info.vdisplay]
    mov [rdx + 8], eax  ; height
    mov eax, [fb_pitch]
    mov [rdx + 12], eax ; pitch
    mov dword [rdx + 16], 32 ; bpp
    mov dword [rdx + 20], 24 ; depth (color depth, usually 24 for 32bpp)
    mov eax, [fb_handle]
    mov [rdx + 24], eax ; handle

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov rsi, DRM_IOCTL_MODE_ADDFB
    ; rdx points to struct
    syscall

    test rax, rax
    js .fail_cleanup_stack

    ; Success, get the framebuffer ID
    mov eax, [rdx]
    mov [fb_id], eax
    add rsp, 32

    xor rax, rax ; return 0 for success
    ret

.fail_cleanup_stack:
    add rsp, 32
    mov rax, 1
    ret


; -------------------------------------------------------------------------
; draw_gradient
; Fills the mmap'd screen buffer with a color gradient.
; -------------------------------------------------------------------------
draw_gradient:
    mov r15, [screen_ptr]           ; r15 = base address of screen buffer
    movzx r14, word [mode_info.vdisplay] ; r14 = height
    movzx r13, word [mode_info.hdisplay] ; r13 = width
    mov r12d, [fb_pitch]            ; r12 = pitch (bytes per row)
    xor r11, r11                    ; r11 = y (row counter)

.y_loop:
    cmp r11, r14
    jge .done
    xor r10, r10                    ; r10 = x (column counter)

.x_loop:
    cmp r10, r13
    jge .next_y

    ; Calculate pixel color (32-bit: 0x00RRGGBB)
    ; We'll make a gradient where Red depends on x, and Green depends on y.
    mov r9, r10                     ; R = x
    shl r9, 8                       ; A little bit of scaling
    shr r9, 8                       ; to fit in 8 bits
    mov r8, r11                     ; G = y
    shl r8, 8
    shr r8, 8

    ; --- START OF CHANGED BLOCK ---
    ; Correctly and safely build the 32-bit color 0x00RRGGBB
    ; R = r9b, G = r8b, B = 128
    movzx eax, r9b    ; eax = 0x000000RR (Red)
    shl eax, 8        ; eax = 0x0000RR00
    movzx ebx, r8b    ; ebx = 0x000000GG (Green)
    or eax, ebx       ; eax = 0x0000RRGG
    shl eax, 8        ; eax = 0x00RRGG00
    or al, 128        ; eax = 0x00RRGGBB (Blue)
    ; --- END OF CHANGED BLOCK ---

    ; Calculate pixel address: base + (y * pitch) + (x * 4)
    mov rbx, r11
    mul r12d                        ; rax = r11 * r12d (y * pitch)
    add rax, r15                    ; rax = base + (y * pitch)
    mov rbx, r10
    shl rbx, 2                      ; rbx = x * 4
    add rax, rbx                    ; rax = final address

    ; Write the pixel
    mov [rax], eax

    inc r10
    jmp .x_loop

.next_y:
    inc r11
    jmp .y_loop

.done:
    ret

%define msg_done.len $ - msg_done
