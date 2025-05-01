; =============================================================================
; BareMetal -- a 64-bit OS written in Assembly for x86-64 systems
; Copyright (C) 2008-2025 Return Infinity -- see LICENSE.TXT
;
; Input/Output Functions
; =============================================================================


; -----------------------------------------------------------------------------
; b_input -- Scans keyboard for input
;  IN:	Nothing
; OUT:	AL = 0 if no key pressed, otherwise ASCII code, other regs preserved
;	All other registers preserved
b_input:
	mov al, [key]
	test al, al
	jz b_input_no_key
	mov byte [key], 0x00		; clear the variable as the keystroke is in AL now
	ret

b_input_no_key:
	bt qword [os_SysConfEn], 1 << 2
	jnc b_input_no_serial
	call serial_recv		; Try from the serial port
b_input_no_serial:
	ret
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; b_output -- Outputs characters
;  IN:	RSI = message location (non zero-terminated)
;	RCX = number of chars to output
; OUT:	All registers preserved
b_output:
	push rsi			; Message location
	push rcx			; Counter of chars left to output
	push rax			; AL is used for the output function

	call [0x00100018]

;	bt qword [os_SysConfEn], 1 << 2
;	jnc b_output_done
;
;b_output_nextchar:
;	jrcxz b_output_done		; If RCX is 0 then the function is complete
;	dec rcx
;	lodsb				; Get char from string and store in AL
;	call serial_send
;	jmp b_output_nextchar

b_output_done:
	pop rax
	pop rcx
	pop rsi
	ret
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; b_input_string -- Take string from keyboard entry
;  IN:	RDI = location where string will be stored
; OUT:	RCX = length of string that was received (NULL not counted)
;	All other registers preserved

b_input_string:
	push rdi
	push rcx
	push rax

b_input_more:
	mov al, '_'			; Cursor character
	call output_char		; Output the cursor
	mov al, 0x03			; Decrement cursor
	call output_char		; Output the cursor

b_input_halt:
	hlt				; Halt until an interrupt is received
	call b_input			; Returns the character entered. 0 if there was none
	jz b_input_halt		; If there was no character then halt until an interrupt is received
b_input_process:
	cmp al, 0x1C			; If Enter key pressed, finish
	je b_input_done
	cmp al, 0x0E			; Backspace
	je b_input_backspace
	cmp al, 32			; In ASCII range (32 - 126)?
	jl b_input_more
	cmp al, 126
	jg b_input_more
	stosb				; Store AL at RDI and increment RDI by 1
	inc rcx			; Increment the length of the string
	call output_char		; Display char
	jmp b_input_more

b_input_backspace:
	test rcx, rcx			; backspace at the beginning? get a new char
	jz b_input_more
	mov al, ' '
	call output_char		; Output backspace as a character
	mov al, 0x03			; Decrement cursor
	call output_char		; Output the cursor
	mov al, 0x03			; Decrement cursor
	call output_char		; Output the cursor
	dec rdi				; go back one in the string
	mov byte [rdi], 0x00		; NULL out the char
	dec rcx			; Decrement the length of the string
	jmp b_input_more

b_input_done:
	xor al, al
	stosb				; We NULL terminate the string
	mov al, ' '
	call output_char		; Overwrite the cursor

	pop rax
	pop rcx
	pop rdi
	ret
; -----------------------------------------------------------------------------


; -----------------------------------------------------------------------------
; output_char -- Displays a char
;  IN:	AL  = char to display
; OUT:	All registers preserved
output_char:
	push rsi
	push rcx

	mov [tempchar], al
	mov rsi, tempchar
	mov ecx, 1
	call b_output

	pop rcx
	pop rsi
	ret
; -----------------------------------------------------------------------------

tempchar: db 0, 0, 0

; =============================================================================
; EOF
