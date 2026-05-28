; legacy_stdio.ll — Minimal stdio via kernel32 (no CRT needed)
; B+ v4.0.0 BETA

declare dllimport ptr @GetStdHandle(i32)
declare dllimport i32 @WriteFile(ptr, ptr, i32, ptr, ptr)

define i32 @puts(ptr %str) {
  %h = call ptr @GetStdHandle(i32 -11)
  %len = call i32 @strlen(ptr %str)
  %written = alloca i32, align 4
  %ok = call i32 @WriteFile(ptr %h, ptr %str, i32 %len, ptr %written, ptr null)
  %nl = alloca i8, align 1
  store i8 10, ptr %nl
  %ok2 = call i32 @WriteFile(ptr %h, ptr %nl, i32 1, ptr %written, ptr null)
  ret i32 %ok
}

define internal i32 @strlen(ptr %s) {
entry:
  %p = ptrtoint ptr %s to i64
  br label %loop
loop:
  %offs = phi i64 [0, %entry], [%next, %loop]
  %addr = getelementptr i8, ptr %s, i64 %offs
  %c = load i8, ptr %addr
  %is_zero = icmp eq i8 %c, 0
  %next = add i64 %offs, 1
  br i1 %is_zero, label %done, label %loop
done:
  %result32 = trunc i64 %offs to i32
  ret i32 %result32
}

; bplus_write: write a buffer of given length to stdout (no newline appended)
define void @bplus_write(ptr %buf, i32 %len) {
  %h = call ptr @GetStdHandle(i32 -11)
  %written = alloca i32, align 4
  %ok = call i32 @WriteFile(ptr %h, ptr %buf, i32 %len, ptr %written, ptr null)
  ret void
}

; bplus_print_i32: print a signed decimal integer to stdout (no newline)
define void @bplus_print_i32(i32 %val) {
entry:
  %buf = alloca [12 x i8], align 1
  %is_neg = icmp slt i32 %val, 0
  br i1 %is_neg, label %neg_start, label %convert

neg_start:
  %abs_val = sub i32 0, %val
  br label %convert

convert:
  %n = phi i32 [%val, %entry], [%abs_val, %neg_start]
  %ptr = getelementptr i8, ptr %buf, i64 12
  %end = getelementptr i8, ptr %ptr, i64 -1
  store i8 0, ptr %end
  br label %divloop

divloop:
  %val_i = phi i32 [%n, %convert], [%quot, %divloop]
  %pos = phi ptr [%end, %convert], [%prev, %divloop]
  %quot = udiv i32 %val_i, 10
  %rem = urem i32 %val_i, 10
  %dig = trunc i32 %rem to i8
  %dig_char = add i8 %dig, 48
  %prev = getelementptr i8, ptr %pos, i64 -1
  store i8 %dig_char, ptr %prev
  %done = icmp eq i32 %quot, 0
  br i1 %done, label %emit, label %divloop

emit:
  %start = phi ptr [%prev, %divloop]
  %need_minus = icmp slt i32 %val, 0
  br i1 %need_minus, label %emit_minus, label %emit_ok

emit_minus:
  %mstart = getelementptr i8, ptr %start, i64 -1
  store i8 45, ptr %mstart
  br label %emit_ok

emit_ok:
  %final_start = phi ptr [%start, %emit], [%mstart, %emit_minus]
  %end_int = ptrtoint ptr %end to i64
  %start_int = ptrtoint ptr %final_start to i64
  %diff = sub i64 %end_int, %start_int
  %len32 = trunc i64 %diff to i32
  call void @bplus_write(ptr %final_start, i32 %len32)
  ret void
}
