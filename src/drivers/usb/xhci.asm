; =============================================================================
; BareMetal -- a 64-bit OS written in Assembly for x86-64 systems
; Copyright (C) 2008-2025 Return Infinity -- see LICENSE.TXT
;
; XHCI (USB 3) Driver
; =============================================================================


; -----------------------------------------------------------------------------
xhci_init:
	push rdx			; RDX should already point to a supported device for os_bus_read/write

	; Gather the Base I/O Address of the device
	mov al, 0			; Read BAR0
	call os_bus_read_bar
	mov [os_XHCI_Base], rax
	mov rsi, rax			; RSI holds the base for MMIO

	; Set PCI Status/Command values
	mov dl, 0x01			; Read Status/Command
	call os_bus_read
	bts eax, 10			; Set Interrupt Disable
	bts eax, 2			; Enable Bus Master
	bts eax, 1			; Enable Memory Space
	call os_bus_write		; Write updated Status/Command

	; Mark controller memory as un-cacheable
	mov rax, [os_XHCI_Base]
	shr rax, 18
	and al, 0b11111000		; Clear the last 3 bits
	mov rdi, 0x10000		; Base of low PDE
	add rdi, rax
	mov rax, [rdi]
	btc rax, 3			; Clear PWT to disable caching
	bts rax, 4			; Set PCD to disable caching
	mov [rdi], rax

	; Gather CAPLENGTH, check HCIVERSION, get offsets
	mov eax, [rsi+XHCI_CAPLENGTH]	; Read 4 bytes starting at CAPLENGTH
	mov [xhci_caplen], al		; Save the CAPLENGTH offset
	; Check for a valid version number
	shr eax, 16			; 16-bit version is in bits 31:16, shift to 15:0
	cmp ax, 0x0100			; Verify it is at least v1.0
	jl xhci_init_error
	mov eax, [rsi+XHCI_HCSPARAMS1]	; Gather MaxSlots (bits 7:0)
	and eax, 0x000000FF		; Keep bits 7:0
	mov byte [xhci_maxslots], al
	xor eax, eax
	mov al, [xhci_caplen]
	add rax, rsi			; RAX points to base of Host Controller Operational Registers
	mov [xhci_op], rax
	mov eax, [rsi+XHCI_DBOFF]	; Read the xHCI Doorbell Offset Register
	and eax, 0xFFFFFFFC		; Clear bits 1:0
	mov [xhci_db], rax
	mov eax, [rsi+XHCI_RTSOFF]	; Read the xHCI Runtime Register Base Offset Register
	and eax, 0xFFFFFFE0		; Clear bits 4:0
	mov [xhci_rt], rax

; QEMU xHCI Extended Capabilities Entries
; 00000000febf0020: 0x02 0x04 0x00 0x02 0x55 0x53 0x42 0x20 <- USB 2
; 00000000febf0028: 0x05 0x04 0x00 0x00 0x00 0x00 0x00 0x00 <- Offset 5, Count 4
; 00000000febf0030: 0x02 0x00 0x00 0x03 0x55 0x53 0x42 0x20 <- USB 3
; 00000000febf0038: 0x01 0x04 0x00 0x00 0x00 0x00 0x00 0x00 <- Offset 1, Count 4

;	; Process xHCI Extended Capabilities Entries (16 bytes each)
;	xor ebx, ebx
;	mov ebx, [rsi+XHCI_HCCPARAMS1]	; Gather xECP (bits 31:16)
;	and ebx, 0xFFFF0000		; Keep only bits 31:16
;	shr ebx, 14			; Shift right for xECP * 4
;xhci_xecp_read:
;	mov eax, [rsi+rbx]		; Load first 4 bytes
;	cmp al, 0x01			; Legacy Entry
;	je xhci_xecp_read_legacy
;	cmp al, 0x02			; Supported Protocols
;	je xhci_xecp_read_supported_protocol
;	jmp xhci_xecp_read_next
;xhci_xecp_read_legacy:
;	; Release BIOS ownership
;	; Set bit 24 to indicate to the BIOS to release ownership
;	; The BIOS should clear bit 16 indicating it has successfully done so
;	; Ownership is released when bit 24 is set *and* bit 16 is clear
;	jmp xhci_xecp_read_next
;xhci_xecp_read_supported_protocol:
;	; Parse the supported protocol if needed
;xhci_xecp_read_next:
;	mov eax, [rsi+rbx]		; Load first 4 bytes of entry again
;	shr eax, 8			; Shift Next to AL
;	and eax, 0x000000FF		; Keep only AL
;	jz xhci_xecp_end		; If AL = 0 then we are at the end
;	shl eax, 2
;	add rbx, rax
;	jmp xhci_xecp_read
;xhci_xecp_end:

	; Reset the controller
xhci_init_halt:
	mov rsi, [xhci_op]		; XHCI Operational Registers Base
	mov eax, [rsi+XHCI_USBCMD]	; Read current Command Register value
	bt eax, 0			; Check RS (bit 0)
	jnc xhci_init_reset		; If the bit was clear, proceed to reset
	btc eax, 0			; Clear RS (bit 0)
	mov [rsi+XHCI_USBCMD], eax	; Write updated Command Register value
	mov rax, 20000			; Wait 20ms (20000µs)
	call b_delay
	mov eax, [rsi+XHCI_USBSTS]	; Read Status Register
	bt eax, 0			; Check HCHalted (bit 0) - it should be 1
	jnc xhci_init_error		; Bail out if HCHalted wasn't cleared after 20ms
xhci_init_reset:
	mov eax, [rsi+XHCI_USBCMD]	; Read current Command Register value
	bts eax, 1			; Set HCRST (bit 1)
	mov [rsi+XHCI_USBCMD], eax	; Write updated Command Register value
	mov rax, 100000			; Wait 100ms (100000µs)
	call b_delay
	mov eax, [rsi+XHCI_USBSTS]	; Read Status Register
	bt eax, 11			; Check CNR (bit 11)
	jc xhci_init_error		; Bail out if CNR wasn't cleared after 100ms
	mov eax, [rsi+XHCI_USBCMD]	; Read current Command Register value
	bt eax, 1			; Check HCRST (bit 1)
	jc xhci_init_error		; Bail out if HCRST wasn't cleared after 100ms

	; Event Ring Setup
	mov rcx, 8                         ; Event ring size (8 entries for simplicity)
	mov rdi, os_XHCI_EVENT_RING         ; Event Ring base address
	mov rsi, os_XHCI_ERST               ; Event Ring Segment Table base address
	mov rdx, rcx                        ; Segment table size (number of entries)

	mov r8, rsi

	; Configure Event Ring Segment Table Entry
	mov rax, rdi                        ; Set the base address of the Event Ring
	mov [rsi], rax                      ; ERST Entry 0: Base Address
	mov [rsi + 8], rdx                  ; ERST Entry 0: Segment Size (number of entries)
	
	; Configure the Runtime Registers for Event Ring
	mov rdi, [xhci_rt]                  ; Get Runtime Register Base Address
	add rdi, XHCI_IR_0                  ; Interrupt Register 0
	mov rax, r8                        ; ERST Base Address
	mov [rdi + XHCI_IR_ERSTB], rax      ; Write ERST Base Address to Interrupt Register
	mov rax, rdi                        ; Event Ring Dequeue Pointer (ERDP)
	mov [rdi + XHCI_IR_ERDP], rax       ; Write ERDP
	mov [rdi + XHCI_IR_ERSTS], rcx      ; Write ERST Size

	; Configure the controller
	mov rsi, [xhci_op]
	mov rax, os_XHCI_DEVICE_CONTEXT
	mov [rsi+XHCI_DCBAPP], rax	; Set the Device Context Base Address Array Pointer Register
	mov rax, os_XHCI_COMMAND_RING
	bts rax, 0			; Set RCS (bit 0)
	mov [rsi+XHCI_CRCR], rax	; Set the Command Ring Control Register
	xor eax, eax
	mov al, [xhci_maxslots]
	mov [rsi+XHCI_CONFIG], eax
	mov eax, 1
	mov [rsi+XHCI_DNCTRL], eax
	mov eax, 0x01			; Set bits 0 (RS)
	mov [rsi+XHCI_USBCMD], eax
    
	; Check the available ports and reset them
	xor ecx, ecx			; Slot counter
	xor edx, edx			; Max slots
	mov dl, byte [xhci_maxslots]
xhci_check_next:
	mov ebx, 0x400			; Offset to start of Port Registers
	shl ecx, 4			; Quick multiply by 16
	add ebx, ecx			; Add offset to EBX
	shr ecx, 4			; Quick divide by 16
	mov eax, [rsi+rbx]		; Load PORTSC
	bt eax, 0			; Current Connect Status
	jnc xhci_reset_skip
	bts eax, 4			; Port Reset
	mov [rsi+rbx], eax
xhci_reset_skip:
	inc ecx
	cmp ecx, edx
	jne xhci_check_next
    ; jmp xhci_init_done                 ; If all slots are Reset, jump to init done

    xor ecx, ecx                      ; Reset Slot Counter
    mov dl, byte [xhci_maxslots]      ; Load Max Slots into DL

xhci_enable_slots_loop:
    mov ebx, 0x400                    ; Base offset of Port Registers (Port 1 starts here)
    shl ecx, 4                        ; Multiply ECX by 16 (each port has a 16-byte register set)
    add ebx, ecx                      ; Add the offset to EBX
    shr ecx, 4                        ; Divide ECX back to original value for slot tracking
    mov rbx, [rsi + rbx]              ; Load the PORTSC register for the current port

    bt rbx, 0                         ; Test bit 0 (Port Connect Status)
    jnc xhci_enable_slots_next        ; If not connected, skip to the next port

    ; Enable Slot for the connected device
    mov rdi, os_XHCI_COMMAND_RING     ; Command Ring base address
    mov rax, [rdi]                    ; Read the Command Ring Control Register (CRCR)
    bts rax, 0                        ; Set the Slot Enable bit (bit 0)
    mov [rdi], rax                    ; Write the updated value back to CRCR

    ; Prepare a Slot Enable Command TRB
    mov rdi, os_XHCI_TRB_BASE         ; TRB base address (where TRBs are stored)
    xor rax, rax                      ; Clear RAX for new TRB preparation

    ; Slot Enable Command TRB
    mov dword [rdi], 0x00             ; Clear DWORD0
    mov dword [rdi + 4], 0x00         ; Clear DWORD1
    mov dword [rdi + 8], 0x00         ; Clear DWORD2

    ; Set TRB Type and Cycle Bit in DWORD3
    mov eax, 0x09                     ; TRB Type = Enable Slot Command (0x09)
    bts eax, 0                        ; Set the Cycle Bit (bit 0)
    mov [rdi + 12], eax               ; Write DWORD3 (TRB Type and Cycle Bit)

    ; Write the TRB to the Command Ring
    mov rbx, [rdi]                    ; Load the TRB
    mov [rsi + XHCI_CRCR + 8], rbx    ; Write the TRB to the Command Ring

    ; Ring the Doorbell for the Command Ring
    mov eax, 0x01                     ; Doorbell for Slot 0 (Command Ring, Enable Slot Command)
    mov [xhci_db + XHCI_CDR], eax     ; Write to the Doorbell Register

xhci_enable_slots_next:
    inc ecx
    cmp ecx, edx                      ; Compare current slot with max slots
    jne xhci_enable_slots_loop        ; If more slots to enable, repeat the process

    jmp xhci_init_done

xhci_init_error:
	jmp $

xhci_init_done:

	pop rdx
	ret

xhci_caplen:	db 0
xhci_maxslots:	db 0
xhci_op:	dq 0			; Start of Operational Registers
xhci_db:	dq 0			; Start of Doorbell Registers
xhci_rt:	dq 0			; Start of Runtime Registers
; -----------------------------------------------------------------------------


; Register list

; Host Controller Capability Registers (Read-Only)
XHCI_CAPLENGTH	equ 0x00	; 1-byte Capability Registers Length
XHCI_HCIVERSION	equ 0x02	; 2-byte Host Controller Interface Version Number
XHCI_HCSPARAMS1	equ 0x04	; 4-byte Structural Parameters 1
XHCI_HCSPARAMS2	equ 0x08	; 4-byte Structural Parameters 2
XHCI_HCSPARAMS3	equ 0x0C	; 4-byte Structural Parameters 3
XHCI_HCCPARAMS1	equ 0x10	; 4-byte Capability Parameters 1
XHCI_DBOFF	equ 0x14	; 4-byte Doorbell Offset
XHCI_RTSOFF	equ 0x18	; 4-byte Runtime Registers Space Offset
XHCI_HCCPARMS2	equ 0x1C	; 4-byte Capability Parameters 2 (XHCI v1.1+)
XHCI_VTIOSOFF	equ 0x20	; 4-byte VTIO Register Space Offset (XHCI v1.2+)

; Host Controller Operational Registers (Starts at XHCI_Base + CAPLENGTH)
XHCI_USBCMD	equ 0x00	; 4-byte USB Command Register
XHCI_USBSTS	equ 0x04	; 4-byte USB Status Register
XHCI_PAGESIZE	equ 0x08	; 4-byte Page Size Register (Read-Only)
XHCI_DNCTRL	equ 0x14	; 4-byte Device Notification Control Register
XHCI_CRCR	equ 0x18	; 8-byte Command Ring Control Register
XHCI_DCBAPP	equ 0x30	; 8-byte Device Context Base Address Array Pointer Register
XHCI_CONFIG	equ 0x38	; 4-byte Configure Register

; Host Controller USB Port Register Set (Starts at XHCI_Base + CAPLENGTH + 0x0400 - 16 bytes per port)
XHCI_PORTSC	equ 0x00	; 4-byte Port Status and Control Register
XHCI_PORTPMSC	equ 0x04	; 4-byte Port PM Status and Control Register
XHCI_PORTLI	equ 0x08	; 4-byte Port Link Info Register (Read-Only)
XHCI_PORTHLPMC	equ 0x0C	; 4-byte Port Hardware LPM Control Register

; Host Controller Doorbell Register Set (Starts at XHCI_Base + CAPLENGTH + DBOFF)
XHCI_CDR	equ 0x00	; 4-byte Command Doorbell Register (Target bits 7:0)
XHCI_DS1	equ 0x04	; 4-byte Device Slot #1 Doorbell
XHCI_DS2	equ 0x08	; 4-byte Device Slot #2 Doorbell

; Host Controller Runtime Register Set (Starts at XHCI_Base + CAPLENGTH + RTSOFF)
XHCI_MICROFRAME	equ 0x00	; 4-byte Microframe Index Register
; Microframe is incremented every 125 microseconds. Each frame (1ms) is 8 microframes
; 28-bytes padding
XHCI_IR_0	equ 0x20	; 32-byte Interrupter Register Set 0
XHCI_IR_1	equ 0x40	; 32-byte Interrupter Register Set 1

; Interrupter Register Set
XHCI_IR_IMR	equ 0x00	; 4-byte Interrupter Management Register
XHCI_IR_IM	equ 0x04	; 4-byte Interrupter Moderation
XHCI_IR_ERSTS	equ 0x08	; 4-byte Event Ring Segment Table Size
; 4-byte padding
XHCI_IR_ERSTB	equ 0x10	; 8-byte Event Ring Segment Table Base Address
XHCI_IR_ERDP	equ 0x18	; 8-byte Event Ring Dequeue Pointer

; =============================================================================
; EOF