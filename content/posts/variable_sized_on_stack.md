+++
title = 'How variable sized arrays work: non-fixed size data on the stack.'
date = 2025-04-13
draft = false
+++

Let's first give some background on why I wanted to create this post.
Local variables are stored on the stack, these variables are usually fixed size, which makes addressing them very
easy. The `rbp` register stores a pointer to an address on the stack, called the stack frame.
Local variables are offset by some constant value relative to the stack frame.

<!--<style>-->
<!--table tr th:empty {-->
<!--  display: none;-->
<!--}-->
<!--</style>-->

| address | | |
|-|-|-|
| 10 | | <-- rsp, growing stack pointer|
| 11 |local_var3||
| 12 |local_var2||
| 13 |local_var1||
| 14 | |<-- rbp, the stack frame|

> 💡 Note that the stack grows downwards, meaning the address of the top of the stack
decreases as variables are stored on the stack.

Addressing these local variables can be done using a single instruction, and thus
is very fast.
For example moving `local_var1` and `local_var3` into registers and adding them
can be done like this:
```NASM
mov    r1, [rbp-1]
mov    r2, [rbp-3]
add    r1, r2
```

For addressing like this to work the variables on the stack need to be fixed size,
because the offsets relative to the stack frame are hard coded at compile time.

## Variable sized arrays in C
Having heard in some places that variables on the stack are actually exclusively fixed size,
I was left very confused after discovering variable sized arrays in C.
Variable sized arrays can be created like this:
```C
int arr[n];
```
This creates a local variable containing an array of size `n`, stored on the stack.[^1]

Well how does this work? Wouldn't this mess with the fixed offset of the local variables?
Indeed, treating it like any other fixed size local variable would not work.
| address | | |
|-|-|-|
| 10| | <-- rsp, growing stack pointer|
| 11|local_var2||
| 12|array_item1||
| 13|array_item2||
| 14|array_item3||
| 15|array_item4||
| 16|local_var1||
| 17| |<-- rbp, the stack frame|

> 💡 Note that arrays are addressed upward, so as the index increases
the memory address increases, so in the opposite direction to which the stack grows.

How would we address `local_var2` in this case? 
Here we could simply do `rbp-6`. However, this would stop working once
we create a different sized array.

To solve this we can store the offset of the array in another local variable, and calculate the address using that offset.
| address | | |
|-|-|-|
| 10 | | <-- rsp, growing stack pointer|
| 11 |local_var2||
| 12 |array_item1||
| 13 |array_item2||
| 14 |array_item3||
| 15 |array_item4||
| 16 |local_var1||
| 17 |array_offset| (-6)|
| 18 | |<-- rbp, the stack frame|

If we now wanted to, for example, add `array_item1` and `local_var2` we could do it like this.

```NASM
; move address of array_item1 into r1
mov    r1, [rbp-1]
add    r1, rbp
; set r2 to array_item1
mov    r2, [r1]
; subtract 1 from address of array_item 1, so address of local_var2
sub    r1, 1
; set r3 to local_var2
mov    r3, [r1]
; add array_item1 and local_var2
add    r2, r3
```

## In practice

The above example is somewhat oversimplified, how it is actually done in practice
is quite different.
So let's have a look at how an actual compiler, compiles this simple c program:
```C
#include <stdio.h>

void function(unsigned size){
    unsigned arr[size];
    for(unsigned i = 0; i<size; i++){
        arr[i]=i;
    }
    printf("arr: First: %d, Last: %d\n", arr[0], arr[size-1]);
    unsigned arr2[size];
    for(unsigned i = 0; i<size; i++){
        arr2[i]=i*2;
    }
    printf("arr2: First: %d, Last: %d\n", arr2[0], arr2[size-1]);
}

int main() {
    function(3);
    return 0;
}
```

It was compiled using gcc on an x86_64 machine:
```bash
> gcc var.c -O0
```

The general strategy goes like this: the fixed size variables are located at the
start of the stack frame, along with an additional variable for each array storing 
the starting position of the array.
These variables can still be addressed using a single instruction.
The variable sized arrays are then just put on top of the stack,
they can be addressed by using the additional variable.

Let's have a look at the what the array allocation compiles to.
```C
unsigned arr[size];
```

We simply grow the stack by `size * 4` as a single unsigned int is 4 bytes.
There is just some extra fancy arithmetic
to assure the stack pointer stays 16-byte aligned.[^2]

```NASM
401157: lea    rdx,[rax*4+0x0] ; rdx = rax * 4 = size * 4
40115f: mov    eax,0x10 ; eax = 16
401164: sub    rax,0x1 ;  rax = 16 - 1
401168: add    rax,rdx ;  rax = size * 4 + 16 - 1
40116b: mov    edi,0x10 ; edi = 16
401170: mov    edx,0x0  ; edx = 0
401175: div    rdi ; rax = rax / rdi = (size * 4 + 16 - 1) / 16
401178: imul   rax,rax,0x10 ; rax = rax * 16
40117c: sub    rsp,rax ; grow stack by previously calculated size
```

Next we save the starting address of the array, which is on the newly allocated stack space.
Once again we have some fancy arithmetic here, this time it simply rounding up
to the nearest 4 bytes, in order to make it 4 byte aligned.
```NASM
40117f: mov    rax,rsp
401182: add    rax,0x3 ; rax = rsp + 3
401186: shr    rax,0x2 ; shift right by two, equivalent to dividing by 4
40118a: shl    rax,0x2 ; shift left by two, equivalent to dividing by 4 
40118e: mov    QWORD PTR [rbp-0x28],rax ; save address on the stack
```

Our stack now looks like this:
| Address | Content | Value | |
| - | - | - |-  |
| rbp - 0x58 | arr begin | | <-- rsp|
| rbp - 0x44 | size | 3 | |
| rbp - 0x28 | address of arr | rbp - 0x58|
| rbp | | | <-- rbp |

With the memory for the list allocated now, assigning values to the array is quite trivial.
At the address `arr_begin + i * (size of int)` the value is written.

```C
for(unsigned i = 0; i<size; i++){
    arr[i]=i;
}
```

```NASM
; Loop initialization 
401192:	mov    DWORD PTR [rbp-0x14],0x0   ; i = 0
401199:	jmp    4011ac <function+0x76>     ; jump to loop condition check (4011ac)
; Loop body
40119b:	mov    rax,QWORD PTR [rbp-0x28]
40119f:	mov    edx,DWORD PTR [rbp-0x14]
4011a2:	mov    ecx,DWORD PTR [rbp-0x14]
4011a5:	mov    DWORD PTR [rax+rdx*4],ecx ; [arr_begin + i * (size of int)] = arr[i] = i
4011a8:	add    DWORD PTR [rbp-0x14],0x1  ; i++
; Loop condition
4011ac:	mov    eax,DWORD PTR [rbp-0x14]
4011af:	cmp    eax,DWORD PTR [rbp-0x44]  ; i < size
4011b2:	jb     40119b <function+0x65>    ; jump to loop body if i < size
```

Our stack now looks like this:
| Address | Content | Value | |
| - | - | - | - |
| rbp - 0x58 | arr[0] | 0  |<-- rsp|
| rbp - 0x54 | arr[1] | 1|  |
| rbp - 0x50 | arr[2] | 2|  |
| rbp - 0x44 | size | 3 | |
| rbp - 0x28 | address of arr | rbp - 0x58 | |
| rbp - 0x14 | i | 2 | |
| rbp | | | <-- rbp |

The second allocation of the array works identically to the first one:
```C
unsigned arr2[size];
```
```NASM
4011e9:	lea    rdx,[rax*4+0x0] ; rdx = rax * 4 = size * 4
4011f1:	mov    eax,0x10 ; eax = 16
4011f6:	sub    rax,0x1 ;  rax = 16 - 1
4011fa:	add    rax,rdx ;  rax = size * 4 + 16 - 1
4011fd:	mov    ecx,0x10 ; ecx = 16
401202:	mov    edx,0x0  ; edx = 0
401207:	div    rcx ; rax = rax / rcx = (size * 4 + 16 - 1) / 16
40120a:	imul   rax,rax,0x10  ; rax = rax * 16
40120e:	sub    rsp,rax ; grow stack by previously calculated size
401211:	mov    rax,rsp
401214:	add    rax,0x3 ; rax = rsp + 3
401218:	shr    rax,0x2 ; shift right by two, equivalent to dividing by 4
40121c:	shl    rax,0x2 ; shift left by two, equivalent to dividing by 4 
401220:	mov    QWORD PTR [rbp-0x38],rax ; save address on the stack
```

And the second for loop is also pretty much identical to the first one:
```C
for(unsigned i = 0; i<size; i++){
    arr2[i]=i*2;
}
```
```NASM
; Loop initialization 
401224:	mov    DWORD PTR [rbp-0x18],0x0
40122b:	jmp    401241 <function+0x10b>
; Loop body
40122d:	mov    eax,DWORD PTR [rbp-0x18]
401230:	lea    ecx,[rax+rax*1] ; ecx = i * 2
401233:	mov    rax,QWORD PTR [rbp-0x38]
401237:	mov    edx,DWORD PTR [rbp-0x18]
40123a:	mov    DWORD PTR [rax+rdx*4],ecx ; [arr_begin + i * (size of int)] = arr[i] = i*2
40123d:	add    DWORD PTR [rbp-0x18],0x1
; Loop condition
401241:	mov    eax,DWORD PTR [rbp-0x18]
401244:	cmp    eax,DWORD PTR [rbp-0x44]
401247:	jb     40122d <function+0xf7>
```

In the end the final stack looks like this:
| Address | Content | Value | |
| - | - | - | - |
| rbp - 0x68 | arr2[0] | 0|<-- rsp|
| rbp - 0x64 | arr2[1] | 2||
| rbp - 0x60 | arr2[2] | 4||
| rbp - 0x58 | arr[0] | 0  ||
| rbp - 0x54 | arr[1] | 1|  |
| rbp - 0x50 | arr[2] | 2|  |
| rbp - 0x44 | size | 3 | |
| rbp - 0x38 | address of arr2 | rbp - 0x68 | |
| rbp - 0x28 | address of arr | rbp - 0x58 | |
| rbp - 0x18 | i (second loop)| 2 | |
| rbp - 0x14 | i (first loop)| 2 | |
| rbp | | | <-- rbp |

## Wrapping up
I hope this clarifies the concept of variable stuff on the stack.
I certainly really enjoyed looking at the disassembled code and figuring out how it works,
I learned a lot about assembly and compilers in the process.
If you have any questions feel free to reach out to me,
through mastodon is probably your best bet,
I am also planning on adding a comment section eventually, but haven't gotten around to it yet.

---  

[^1]: Local variables being stored on the stack is technically an implementation detail, the c standard only calls of local variables (auto variables) to be freed once there out of scope. In practice this is always done using the stack.
[^2]: For more details on why it should be 16 byte aligned see the following stack overflow post: <https://stackoverflow.com/questions/49391001/why-does-the-x86-64-amd64-system-v-abi-mandate-a-16-byte-stack-alignment>.
<!--## In practice-->
<!---->
<!--The above example is somewhat oversimplified, how it is actually done in practice-->
<!--is quite different.-->
<!--So lets have a look at how an actual compiler, compiles this simple c program:-->
<!--```C-->
<!--#include <stdio.h>-->
<!---->
<!--void function(unsigned size){-->
<!--    unsigned arr[size];-->
<!--    for(unsigned i = 0; i<size; i++){-->
<!--        arr[i]=i;-->
<!--    }-->
<!--    printf("arr: First: %d, Last: %d\n", arr[0], arr[size-1]);-->
<!--    unsigned arr2[size];-->
<!--    for(unsigned i = 0; i<size; i++){-->
<!--        arr2[i]=i*2;-->
<!--    }-->
<!--    printf("arr2: First: %d, Last: %d\n", arr2[0], arr2[size-1]);-->
<!--}-->
<!---->
<!--int main() {-->
<!--    function(3);-->
<!--    return 0;-->
<!--}-->
<!--```-->
<!---->
<!--It was compiled using gcc:-->
<!--```bash-->
<!-- gcc var.c -O0-->
<!--```-->
<!---->
<!--Lets look at each part of the c code bit by bit and what it compiles to.-->
<!---->
<!--First there is just some standard c calling convention stuff, like saving the-->
<!--previous stack frame etc.-->
<!--```C-->
<!--void function(unsigned size){-->
<!--```-->
<!--```NASM-->
<!--401136:	push   rbp ; save previous stackframe-->
<!--401137:	mov    rbp,rsp ; set new stackframe-->
<!--40113a:	push   rbx ; rbx is callee-saved (convention, not super important)-->
<!--40113b:	sub    rsp,0x48 ; make space for fixed size local variables on stack-->
<!--40113f:	mov    DWORD PTR [rbp-0x44],edi ; edi is the function argument, store it on the stack-->
<!--401142:	mov    rax,rsp-->
<!--401145:	mov    rbx,rax ; Previous stack pointer is saved in rbx-->
<!--```-->
<!--Our stack now looks like this:-->
<!--| Address | Content | |-->
<!--| - | - | - |-->
<!--| rbp - 0x48 | | <-- rsp|-->
<!--| rbp - 0x44 | size | |-->
<!--| rbp | | <-- rbp |-->
<!---->
<!--Next lets have a look at the what the array allocation compiles to.-->
<!--```C-->
<!--unsigned arr[size];-->
<!--```-->
<!--We are saving `size - 1` on the stack, this variable isn't actually used anywhere-->
<!--and would most likely be optimised away with compiler optimisations.-->
<!--```NASM-->
<!--401148: mov    eax,DWORD PTR [rbp-0x44] ; eax = size-->
<!--40114b: mov    edx,eax ; edx = eax = size-->
<!--40114d: sub    rdx,0x1 ; rdx = size - 1-->
<!--401151: mov    QWORD PTR [rbp-0x20],rdx ; save size - 1 in local var (rbp-0x20)-->
<!--401155: mov    eax,eax ; This just does nothing-->
<!--```-->
<!---->
<!--Next we simply grow the stack by `size * 4` as a single unsigned int is 4 bytes.-->
<!--There is just some extra fancy arithmetic-->
<!--to assure the stack pointer stays 16-byte aligned.[^2]-->
<!--```NASM-->
<!--401157: lea    rdx,[rax*4+0x0] ; rdx = rax * 4 = size * 4-->
<!--40115f: mov    eax,0x10 ; eax = 16-->
<!--401164: sub    rax,0x1 ;  rax = 16 - 1-->
<!--401168: add    rax,rdx ;  rax = size * 4 + 16 - 1-->
<!--40116b: mov    edi,0x10 ; edi = 16-->
<!--401170: mov    edx,0x0  ; edx = 0-->
<!--401175: div    rdi ; rax = rax / rdi = (size * 4 + 16 - 1) / 16-->
<!--401178: imul   rax,rax,0x10 ; rax = rax * 16-->
<!--40117c: sub    rsp,rax ; grow stack by previously calculated size-->
<!--```-->
<!---->
<!--Next we save the starting address of the array, which is on the newly allocated stack space.-->
<!--Once again we have same fancy arithmetic here, this time it simply rounding up-->
<!--to the nearest 4 bytes, in order to make it 4 byte aligned.-->
<!--```NASM-->
<!--40117f: mov    rax,rsp-->
<!--401182: add    rax,0x3 ; rax = rsp + 3-->
<!--401186: shr    rax,0x2 ; shift right by two, equivalent to dividing by 4-->
<!--40118a: shl    rax,0x2 ; shift left by two, equivalent to dividing by 4 -->
<!--40118e: mov    QWORD PTR [rbp-0x28],rax ; save address on the stack-->
<!--```-->
<!---->
<!--Our stack now looks like this:-->
<!--| Address | Content | |-->
<!--| - | - | - |-->
<!--| rbp - 0x58 | arr begin | <-- rsp|-->
<!--| rbp - 0x44 | size | |-->
<!--| rbp - 0x28 | address of arr | |-->
<!--| rbp | | <-- rbp |-->
<!---->
<!--With the memory for the list allocated now, assigning values to the array is quite trivial.-->
<!--At the address arr_begin + i * (size of int) the value is written.-->
<!---->
<!--```C-->
<!--for(unsigned i = 0; i<size; i++){-->
<!--    arr[i]=i;-->
<!--}-->
<!--```-->
<!---->
<!--```NASM-->
<!--; Loop initialization -->
<!--401192:	mov    DWORD PTR [rbp-0x14],0x0   ; i = 0-->
<!--401199:	jmp    4011ac <function+0x76>     ; jump to loop condition check (4011ac)-->
<!--; Loop body-->
<!--40119b:	mov    rax,QWORD PTR [rbp-0x28]-->
<!--40119f:	mov    edx,DWORD PTR [rbp-0x14]-->
<!--4011a2:	mov    ecx,DWORD PTR [rbp-0x14]-->
<!--4011a5:	mov    DWORD PTR [rax+rdx*4],ecx ; [arr_begin + i * (size of int)] = arr[i] = i-->
<!--4011a8:	add    DWORD PTR [rbp-0x14],0x1  ; i++-->
<!--; Loop condition-->
<!--4011ac:	mov    eax,DWORD PTR [rbp-0x14]-->
<!--4011af:	cmp    eax,DWORD PTR [rbp-0x44]  ; i < size-->
<!--4011b2:	jb     40119b <function+0x65>    ; jump to loop body if i < size-->
<!--```-->
<!---->
<!--Our stack now looks like this:-->
<!--| Address | Content | |-->
<!--| - | - | - |-->
<!--| rbp - 0x58 | arr[0] | <-- rsp|-->
<!--| rbp - 0x54 | arr[1] | |-->
<!--| rbp - 0x50 | arr[2] | |-->
<!--| rbp - 0x44 | size | |-->
<!--| rbp - 0x28 | address of arr | |-->
<!--| rbp - 0x14 | i | |-->
<!--| rbp | | <-- rbp |-->
<!---->
<!--First print statement-->
<!--```NASM-->
<!--4011b4:	mov    eax,DWORD PTR [rbp-0x44]  ; -->
<!--4011b7:	lea    edx,[rax-0x1]-->
<!--4011ba:	mov    rax,QWORD PTR [rbp-0x28]-->
<!--4011be:	mov    edx,edx-->
<!--4011c0:	mov    edx,DWORD PTR [rax+rdx*4]-->
<!--4011c3:	mov    rax,QWORD PTR [rbp-0x28]-->
<!--4011c7:	mov    eax,DWORD PTR [rax]-->
<!--4011c9:	mov    esi,eax-->
<!--4011cb:	mov    edi,0x402004-->
<!--4011d0:	mov    eax,0x0-->
<!--4011d5:	call   401030 <printf@plt>-->
<!--```-->
<!---->
<!--Second allocation-->
<!--```NASM-->
<!--4011da:	mov    eax,DWORD PTR [rbp-0x44]-->
<!--4011dd:	mov    edx,eax-->
<!--4011df:	sub    rdx,0x1-->
<!--4011e3:	mov    QWORD PTR [rbp-0x30],rdx-->
<!--4011e7:	mov    eax,eax-->
<!--4011e9:	lea    rdx,[rax*4+0x0]-->
<!--4011f0:	-->
<!--4011f1:	mov    eax,0x10-->
<!--4011f6:	sub    rax,0x1-->
<!--4011fa:	add    rax,rdx-->
<!--4011fd:	mov    ecx,0x10-->
<!--401202:	mov    edx,0x0-->
<!--401207:	div    rcx-->
<!--40120a:	imul   rax,rax,0x10-->
<!--40120e:	sub    rsp,rax-->
<!--401211:	mov    rax,rsp-->
<!--401214:	add    rax,0x3-->
<!--401218:	shr    rax,0x2-->
<!--40121c:	shl    rax,0x2-->
<!--401220:	mov    QWORD PTR [rbp-0x38],rax-->
<!--```-->
<!---->
<!--```NASM-->
<!--401224:	mov    DWORD PTR [rbp-0x18],0x0-->
<!--40122b:	jmp    401241 <function+0x10b>-->
<!--40122d:	mov    eax,DWORD PTR [rbp-0x18]-->
<!--401230:	lea    ecx,[rax+rax*1]-->
<!--401233:	mov    rax,QWORD PTR [rbp-0x38]-->
<!--401237:	mov    edx,DWORD PTR [rbp-0x18]-->
<!--40123a:	mov    DWORD PTR [rax+rdx*4],ecx-->
<!--40123d:	add    DWORD PTR [rbp-0x18],0x1-->
<!--401241:	mov    eax,DWORD PTR [rbp-0x18]-->
<!--401244:	cmp    eax,DWORD PTR [rbp-0x44]-->
<!--401247:	jb     40122d <function+0xf7>-->
<!--401249:	mov    eax,DWORD PTR [rbp-0x44]-->
<!--40124c:	lea    edx,[rax-0x1]-->
<!--40124f:	mov    rax,QWORD PTR [rbp-0x38]-->
<!--401253:	mov    edx,edx-->
<!--401255:	mov    edx,DWORD PTR [rax+rdx*4]-->
<!--401258:	mov    rax,QWORD PTR [rbp-0x38]-->
<!--40125c:	mov    eax,DWORD PTR [rax]-->
<!--40125e:	mov    esi,eax-->
<!--401260:	mov    edi,0x40201e-->
<!--401265:	mov    eax,0x0-->
<!--40126a:	call   401030 <printf@plt>-->
<!--```-->
<!---->
<!--```NASM-->
<!--40126f:	mov    rsp,rbx-->
<!--401272:	nop-->
<!--401273:	mov    rbx,QWORD PTR [rbp-0x8]-->
<!--401277:	leave-->
<!--401278:	ret-->
<!--```-->
