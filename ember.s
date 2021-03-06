; memory map:
; [0000; 0400) IVT
; [0400; 0500) BDA
; [    ; 7c00) stack
; [7c00; 7e00) MBR
; [7de0; 7deb) filename buffer
; [7df0; 7e00) EDD disk packet
; [7e00;     ) variables

org 0x7c00
bits 16

%define linebuffer 0x600
; Some BIOSes start with CS=07c0. Make sure this does not wreak havoc
	jmp 0:start

ivtptr:
%define i_biosdisp 0x10
%define i_biosdisk 0x13
%define i_bioskbd  0x16

%define i_readline 0x20
	dw readline

%define i_putchar  0x21
	dw putchar

%define i_diskread 0x22
	dw diskread

%define i_diskwrite 0x23
	dw diskwrite
.end:

start:
	cli
	xor cx, cx
	mov ds, cx
	mov es, cx
	mov ss, cx
	mov sp, 0x7c00
	mov [do_disk.disknum+1], dl
	sti

	cld
	mov di, 0x20 * 4
	mov si, ivtptr
	mov cl, ivtptr.end - ivtptr
.ivtloop:
	movsw
	xor ax, ax
	stosw
	loop .ivtloop

	xor bx, bx
shell:
	mov al, '>'
	int i_putchar

	int i_readline

	; Speculatively parse a new pointer
	mov si, linebuffer
	call readhexword
	jc short .oldaddr
	xchg bx, ax ; mov bx, ax
	mov di, bx
	jmp short .gotaddr
.oldaddr:
	mov si, linebuffer
.gotaddr:

	; command dispatch
	lodsb
	or al, al
	jnz short not_singledump

	mov cx, 1
	jmp short hexdump
not_singledump:
	cmp al, '.'
	jnz short not_rangedump

	call readhexword
	jc short parse_error

	sub ax, bx ; length in bytes
	add ax, 15 ; round up
	shr ax, 4  ; into line count
	mov cx, ax ; prepare loop counter

	call verify_end

; Print a hexdump
; Returns to `shell`
; Input:
;  BX = data pointer
;  CX = line count
; Output:
;  BX = first unprinted byte
;  CX = 0
; Clobbers AX
hexdump:
	mov al, bh
	call writehexbyte
	mov al, bl
	call writehexbyte
	mov al, ':'
	int i_putchar
	push cx
	mov cx, 16
.byteloop:
	mov al, ' '
	int i_putchar
	mov al, [bx]
	inc bx
	call writehexbyte
	loop .byteloop
	mov al, `\r`
	int i_putchar
	pop cx
	loop hexdump
	jmp short shell

not_rangedump:
	cmp al, ':'
	jnz short not_poke
	mov bx, di ; move the read location

.loop:
	lodsb
	or al, al
	jz short shell

	cmp al, ' '
	jz short .loop

	dec si
	call readhexbyte
	jc short parse_error
	stosb
	jmp short .loop

not_poke:
	cmp al, 'g'
	jnz short not_run

	call verify_end
	call di
	jmp short shell

not_run:
	jmp short parse_error ; TODO: make this a direct jump when features are finalized

verify_end:
	lodsb
	or al, al
	jz short readhexbyte.fail ; borrow the return of some other routine
	pop ax ; discard the return address

parse_error:
	dec si
	lodsb
	or al, al
	jz short .skip_char
	int i_putchar
.skip_char:
	mov al, '?'
	int i_putchar
	jmp near shell

; Parse a hexadecimal word.
; Input:
;  SI = input buffer pointer
; Output (success):
;  CF clear
;  AX = parsed word
;  SI = input + 4
; Output (failure):
;  CF set
;  SI = after first invalid character
; Clobbers DL
readhexword:
	call readhexbyte
	jc short readhexbyte.fail
	mov ah, al
	; fallthrough

; Parse a hexadecimal byte.
; Input:
;  SI = input buffer pointer
; Output (success):
;  CF clear
;  AL = parsed byte
;  SI = input + 2
; Output (failure):
;  CF set
;  AL = undefined
;  SI = after invalid character
; Clobbers DL
readhexbyte:
	lodsb
	call readhexchar
	jc short .fail
	shl al, 4
	mov dl, al
	lodsb
	call readhexchar
	jc short .fail
	or al, dl ; carry flag is clear
.fail:
	ret

; Parse a hexadecimal digit.
; Input:
;  AL = ASCII character
; Output (success):
;  CF clear
;  AL = digit value [0; 16)
; Output (failure):
;  CF set
;  AL = undefined
readhexchar:
	sub al, '0'
	jc short .end
	cmp al, 10 ; jb = jc, so right now carry = ok
	cmc ; now, carry = try different range
	jnc short .end
	sub al, 'a' - '0'
	jc short .end
	add al, 10
	cmp al, 16
	cmc ; before, carry = ok. now, carry = error
.end:
	ret

; Write a hexadecimal byte.
; Input:
;  AL = the byte
; Output:
;  (screen)
;  AL = the lower nibble as ASCII
;  DL = the byte, unchanged
writehexbyte:
	mov dl, al
	shr al, 4
	call writehexchar
	mov al, dl
	and al, 0x0f
	; fallthrough

; Write a hexadecimal digit.
; Input:
;  AL = digit [0; 0x10)
; Output:
;  (screen)
;  AL = digit as ASCII
writehexchar:
	add al, '0'
	cmp al, '9'
	jbe .ok
	add al, 'a' - '0' - 10
.ok:
	int i_putchar
	ret

; Interrupt 0x23
; Write sector on the boot disk
; Input:
;  eax = LBA
;  es:di = operation buffer
diskwrite:
	mov byte [do_disk.op+1], 0x43
	jmp short do_disk

; Interrupt 0x22
; Read sector on the boot disk
; Input:
;  eax = LBA
;  es:di = operation buffer
; Stops execution on error
diskread:
	mov byte[do_disk.op+1], 0x42

do_disk:
	pusha
	push ds

	push cs
	pop ds

	mov si, 0x7df0
	mov dword[si], 0x10010
	mov [si+4], di
	mov [si+6], es
	mov [si+8], eax
	xor eax, eax
	mov [si+12], eax
.disknum:
	mov dl, 0 ; overwritten during init
.op:
	mov ah, 0x42 ; overwritten when writing
	int i_biosdisk
	jc short error

	pop ds
	popa
	iret

error:
	mov al, '!'
	int i_putchar
	cli
	hlt

; Interrupt 0x20
; Read a line of text and store it in the global `linebuffer` (0x600). The result is
; null-terminated. No overflow checking is performed.
readline:
	pusha
	cld
	mov di, linebuffer
.loop:
	mov ah, 0
	int i_bioskbd

	cmp al, 8
	jne short .nobackspace
	cmp di, linebuffer
	je short .loop
	dec di
	db 0xb4 ; load the opcode of the stosb to AH to skip its execution
.nobackspace:
	stosb
	int i_putchar

	cmp al, `\r`
	jne short .loop

	dec di ; undo the store of the line terminatior
	mov byte[di], 0
	popa
	iret

; Interrupt 0x21
; Put a character on the screen. Expands \r into \r\n because the latter is required
; by the BIOS for a proper newline. \r is used to signify newlines because that's what
; the keyboard gives us.
; Input:
;  AL = ASCII character
putchar:
	pusha
	mov ah, 0x0e
	xor bx, bx
	int i_biosdisp
	cmp al, `\r` ; all registers are preserved by the BIOS function
	jne short .skip_newline
	mov al, `\n`
	int i_biosdisp
.skip_newline:
	cmp al, `\b`
	jne short .skip_backspace
	mov al, ' '
	int i_biosdisp
	mov al, `\b`
	int i_biosdisp
.skip_backspace:
	popa
	iret

times 446 - ($ - $$) db 0
times 64 db 0xff
	dw 0xaa55
