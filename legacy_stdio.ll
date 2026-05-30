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
