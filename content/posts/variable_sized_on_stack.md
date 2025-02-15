+++
title = 'How variable sized arrays work: non-fixed size data on the stack.'
date = 2025-02-07T20:57:52+01:00
draft = true
+++

Lets first give some background on why I wanted to create this post.
Local variables are stored on the stack, these variables are usually fixed size, which makes addressing them very
easy. The `rbp` register stores a pointer to an adress on the stack, called the stack frame.
A local variables are offset by some constant value relative to the stack frame.

<style>
table tr th:empty {
  display: none;
}
</style>

| | |
|-|-|
| | <-- rsp, growing stack pointer|
|local_var3||
|local_var2||
|local_var1||
| |<-- rbp, the stack frame|

Adressing these local variables can be done using a single instruction, and thus
is very fast.
For example moving `local_var1` and `local_var3` into register and adding them
can be done like this:
```TASM
mov    %r1,-1(%rbp)
mov    %r2,-3(%rbp)
add    %r1,%r2
```

## Variable sized arrays in C
Having heard in some places that variables are actually exclusively fixed size,
I was left very confused after discovering variable sized arrays in C.
Variable sized arrays can be created like this:
```C
int arr[n];
```
This creates a local variable containing an array of size `n`, stored on the stack.
