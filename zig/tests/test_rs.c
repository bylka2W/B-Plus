#include <windows.h>
#include <d3d12.h>
#include <stdio.h>

#pragma comment(lib, "d3d12.lib")

int main() {
    HRESULT hr;
    ID3DBlob *blob = NULL, *err_blob = NULL;

    // Try v1.0 empty
    D3D12_ROOT_SIGNATURE_DESC desc = {};
    desc.NumParameters = 0;
    desc.pParameters = NULL;
    desc.NumStaticSamplers = 0;
    desc.pStaticSamplers = NULL;
    desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_NONE;

    hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1_0, &blob, &err_blob);
    printf("v1.0 empty: hr=0x%08lX blob=%p err=%p\n", (unsigned long)hr, (void*)blob, (void*)err_blob);
    if (blob) {
        printf("  blob size=%llu ptr=%p\n", (unsigned long long)blob->GetBufferSize(), blob->GetBufferPointer());
        blob->Release();
    }
    if (err_blob) {
        printf("  err: %s\n", (const char*)err_blob->GetBufferPointer());
        err_blob->Release();
    }

    // Try with a parameter
    D3D12_ROOT_PARAMETER param = {};
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    param.Constants.ShaderRegister = 0;
    param.Constants.RegisterSpace = 0;
    param.Constants.Num32BitValues = 1;
    param.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;

    desc.NumParameters = 1;
    desc.pParameters = &param;

    hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1_0, &blob, &err_blob);
    printf("v1.0 1param: hr=0x%08lX blob=%p err=%p\n", (unsigned long)hr, (void*)blob, (void*)err_blob);
    if (blob) {
        printf("  blob size=%llu ptr=%p\n", (unsigned long long)blob->GetBufferSize(), blob->GetBufferPointer());
        blob->Release();
    }
    if (err_blob) {
        printf("  err: %s\n", (const char*)err_blob->GetBufferPointer());
        err_blob->Release();
    }
    return 0;
}
