typedef long HRESULT;
typedef struct { void *lpVtbl; } IUnknownVtbl;
typedef struct { IUnknownVtbl *lpVtbl; } IUnknown;
typedef struct { void *lpVtbl; } ID3DBlob;

typedef struct {
    unsigned int NumParameters;
    void *pParameters;
    unsigned int NumStaticSamplers;
    void *pStaticSamplers;
    unsigned int Flags;
} D3D12_ROOT_SIGNATURE_DESC;

typedef HRESULT (__stdcall *SerializeRootSig_t)(const D3D12_ROOT_SIGNATURE_DESC*, unsigned int, ID3DBlob**, ID3DBlob**);
typedef HRESULT (__stdcall *SerializeVersionedRootSig_t)(const void*, ID3DBlob**, ID3DBlob**);

typedef unsigned long long (__stdcall *GetBufferSize_t)(ID3DBlob*);
typedef void* (__stdcall *GetBufferPointer_t)(ID3DBlob*);
typedef unsigned long (__stdcall *Release_t)(IUnknown*);

extern void* __stdcall LoadLibraryA(const char*);
extern void* __stdcall GetProcAddress(void*, const char*);
extern int __stdcall FreeLibrary(void*);
extern int __cdecl printf(const char*, ...);
extern void* __stdcall memset(void*, int, unsigned long long);

int main() {
    void* d3d12 = LoadLibraryA("d3d12.dll");
    if (!d3d12) { printf("load fail\n"); return 1; }

    SerializeRootSig_t fn1 = (SerializeRootSig_t)GetProcAddress(d3d12, "D3D12SerializeRootSignature");
    SerializeVersionedRootSig_t fn2 = (SerializeVersionedRootSig_t)GetProcAddress(d3d12, "D3D12SerializeVersionedRootSignature");

    printf("fn1=%p fn2=%p\n", (void*)fn1, (void*)fn2);

    D3D12_ROOT_SIGNATURE_DESC desc;
    memset(&desc, 0, sizeof(desc));
    ID3DBlob *blob = 0, *err_blob = 0;

    HRESULT hr = fn1(&desc, 1, &blob, &err_blob);
    printf("empty: hr=0x%08lX blob=%p\n", (unsigned long)hr, (void*)blob);
    if (blob) {
        void **vtbl = *(void***)blob;
        GetBufferPointer_t gbp = (GetBufferPointer_t)vtbl[3];
        GetBufferSize_t gbs = (GetBufferSize_t)vtbl[4];
        Release_t rel = (Release_t)vtbl[2];
        printf("  blob vtbl[3]=%p vtbl[4]=%p\n", (void*)gbp, (void*)gbs);
        printf("  size=%llu ptr=%p\n", (unsigned long long)gbs(blob), gbp(blob));
        rel((IUnknown*)blob);
    }
    if (err_blob) {
        void **vtbl = *(void***)err_blob;
        GetBufferPointer_t gbp = (GetBufferPointer_t)vtbl[3];
        printf("  err: %s\n", (const char*)gbp(err_blob));
        Release_t rel = (Release_t)vtbl[2];
        rel((IUnknown*)err_blob);
    }

    FreeLibrary(d3d12);
    return 0;
}
