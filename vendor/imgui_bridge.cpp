// imgui_bridge.cpp — C bridge for ImGui backend functions.
// The backends are compiled as C++ (C++ linkage) but we need C linkage for Zig interop.

#include "imgui.h"
#include "imgui_impl_dx9.h"
#include "imgui_impl_win32.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3d9.h>

// Forward declare (the actual definition is in imgui_impl_win32.cpp with C++ linkage)
extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

extern "C" {

bool bridge_ImplDX9_Init(void* device) {
    return ImGui_ImplDX9_Init((IDirect3DDevice9*)device);
}

void bridge_ImplDX9_Shutdown(void) {
    ImGui_ImplDX9_Shutdown();
}

void bridge_ImplDX9_NewFrame(void) {
    ImGui_ImplDX9_NewFrame();
}

void bridge_ImplDX9_RenderDrawData(void* draw_data) {
    ImGui_ImplDX9_RenderDrawData((ImDrawData*)draw_data);
}

void bridge_ImplDX9_InvalidateDeviceObjects(void) {
    ImGui_ImplDX9_InvalidateDeviceObjects();
}

bool bridge_ImplDX9_CreateDeviceObjects(void) {
    return ImGui_ImplDX9_CreateDeviceObjects();
}

bool bridge_ImplWin32_Init(void* hwnd) {
    return ImGui_ImplWin32_Init(hwnd);
}

void bridge_ImplWin32_Shutdown(void) {
    ImGui_ImplWin32_Shutdown();
}

void bridge_ImplWin32_NewFrame(void) {
    ImGui_ImplWin32_NewFrame();
}

intptr_t bridge_ImplWin32_WndProcHandler(void* hWnd, unsigned int msg, uintptr_t wParam, intptr_t lParam) {
    return (intptr_t)ImGui_ImplWin32_WndProcHandler((HWND)hWnd, msg, (WPARAM)wParam, (LPARAM)lParam);
}

// Set the backbuffer as the current render target.
// nGlide may leave an off-screen surface as the render target after Glide→D3D9 rendering.
// ImGui needs to render directly to the backbuffer to be visible.
void bridge_SetBackBufferRenderTarget(void* device) {
    IDirect3DDevice9* dev = (IDirect3DDevice9*)device;
    IDirect3DSurface9* backBuffer = nullptr;
    if (SUCCEEDED(dev->GetBackBuffer(0, 0, D3DBACKBUFFER_TYPE_MONO, &backBuffer))) {
        dev->SetRenderTarget(0, backBuffer);
        backBuffer->Release();
    }
}

} // extern "C"
