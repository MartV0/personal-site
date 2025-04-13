+++
title = 'Typescript'
date = 2025-02-15T12:38:36+01:00
draft = true
+++

## Examples

```Typescript
export interface ImportResult {
    uid: string,
    key: string
}

let x: ImportResult = blabla;
let y: string = "string" + x; // This is fine??!!
```

```Typescript
x = []
x[5] = "something?"
console.log(x)
```

Returning undefined instead of error
