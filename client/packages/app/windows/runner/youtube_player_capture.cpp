// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_capture.h"

#include <d3d11_4.h>
#include <DispatcherQueue.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.Numerics.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Composition.h>

#include <algorithm>
#include <mutex>

namespace slimm_youtube {
namespace {

namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgd = winrt::Windows::Graphics::DirectX;
namespace wuc = winrt::Windows::UI::Composition;

constexpr auto kFormat = wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized;

winrt::Windows::System::DispatcherQueueController g_queue{nullptr};

// Composition needs a dispatcher queue on the UI thread, which the runner's message loop pumps.
void EnsureDispatcherQueue() {
  if (winrt::Windows::System::DispatcherQueue::GetForCurrentThread()) return;
  DispatcherQueueOptions options{sizeof(DispatcherQueueOptions),
                                 DQTYPE_THREAD_CURRENT, DQTAT_COM_NONE};
  winrt::check_hresult(CreateDispatcherQueueController(
      options, reinterpret_cast<ABI::Windows::System::IDispatcherQueueController**>(
                   winrt::put_abi(g_queue))));
}

winrt::com_ptr<ID3D11Texture2D> SharedTexture(ID3D11Device* device,
                                               UINT width, UINT height,
                                               HANDLE* handle) {
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  winrt::com_ptr<ID3D11Texture2D> texture;
  winrt::check_hresult(device->CreateTexture2D(&desc, nullptr, texture.put()));
  winrt::check_hresult(texture.as<IDXGIResource>()->GetSharedHandle(handle));
  return texture;
}

class Capture final : public VisualCapture,
                      public std::enable_shared_from_this<Capture> {
 public:
  explicit Capture(std::function<void()> on_frame)
      : on_frame_(std::move(on_frame)) {}

  ~Capture() override { Stop(); }

  void Init(IDXGIAdapter* adapter) {
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
                                  D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    winrt::check_hresult(D3D11CreateDevice(
        adapter,
        adapter == nullptr ? D3D_DRIVER_TYPE_HARDWARE : D3D_DRIVER_TYPE_UNKNOWN,
        nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
        static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION, device_.put(),
        nullptr, context_.put()));
    // Frames arrive on a worker thread while the UI thread may resize.
    if (auto multithread = device_.try_as<ID3D11Multithread>()) {
      multithread->SetMultithreadProtected(TRUE);
    }
    winrt::com_ptr<::IInspectable> inspectable;
    winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
        device_.as<IDXGIDevice>().get(), inspectable.put()));
    winrt_device_ = inspectable.as<wgd::Direct3D11::IDirect3DDevice>();
    EnsureDispatcherQueue();
    compositor_ = wuc::Compositor();
    root_ = compositor_.CreateContainerVisual();
    Start(1, 1);
  }

  IUnknown* RootVisual() override {
    return static_cast<IUnknown*>(winrt::get_abi(root_));
  }

  void Resize(UINT width, UINT height) override {
    width = std::max<UINT>(width, 1);
    height = std::max<UINT>(height, 1);
    if (width == size_.Width && height == size_.Height) return;
    try {
      Start(width, height);
    } catch (winrt::hresult_error const&) {
    }
  }

  SharedFrame Latest() override {
    std::lock_guard<std::mutex> guard(lock_);
    return frame_;
  }

 private:
  // A visual's capture item keeps the visual's size from when it was made, so each new size needs a new item.
  void Start(UINT width, UINT height) {
    Stop();
    root_.Size({static_cast<float>(width), static_cast<float>(height)});
    size_ = {static_cast<int32_t>(width), static_cast<int32_t>(height)};
    item_ = wgc::GraphicsCaptureItem::CreateFromVisual(root_);
    pool_ = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
        winrt_device_, kFormat, 2, item_.Size());
    session_ = pool_.CreateCaptureSession(item_);
    try {
      session_.IsCursorCaptureEnabled(false);
    } catch (winrt::hresult_error const&) {
    }
    std::weak_ptr<Capture> weak = shared_from_this();
    arrived_ = pool_.FrameArrived(
        [weak](wgc::Direct3D11CaptureFramePool const& pool,
               winrt::Windows::Foundation::IInspectable const&) {
          if (auto self = weak.lock()) self->OnFrame(pool);
        });
    session_.StartCapture();
  }

  void Stop() {
    try {
      if (pool_) pool_.FrameArrived(arrived_);
      if (session_) session_.Close();
      if (pool_) pool_.Close();
    } catch (winrt::hresult_error const&) {
    }
    session_ = nullptr;
    pool_ = nullptr;
    item_ = nullptr;
  }

  void OnFrame(wgc::Direct3D11CaptureFramePool const& pool) {
    try {
      auto frame = pool.TryGetNextFrame();
      if (!frame) return;
      const auto size = frame.ContentSize();
      auto access = frame.Surface().as<
          ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      winrt::com_ptr<ID3D11Texture2D> source;
      winrt::check_hresult(access->GetInterface(
          winrt::guid_of<ID3D11Texture2D>(), source.put_void()));
      D3D11_TEXTURE2D_DESC desc{};
      source->GetDesc(&desc);
      const UINT width = std::min<UINT>(size.Width, desc.Width);
      const UINT height = std::min<UINT>(size.Height, desc.Height);
      if (width > 0 && height > 0) Copy(source.get(), width, height);
    } catch (winrt::hresult_error const&) {
      return;
    }
    if (on_frame_) on_frame_();
  }

  void Copy(ID3D11Texture2D* source, UINT width, UINT height) {
    std::lock_guard<std::mutex> guard(lock_);
    if (!shared_ || frame_.width != width || frame_.height != height) {
      HANDLE handle = nullptr;
      shared_ = SharedTexture(device_.get(), width, height, &handle);
      frame_ = SharedFrame{handle, width, height};
    }
    D3D11_BOX box{0, 0, 0, width, height, 1};
    context_->CopySubresourceRegion(shared_.get(), 0, 0, 0, 0, source, 0, &box);
    context_->Flush();
  }

  std::function<void()> on_frame_;
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  wgd::Direct3D11::IDirect3DDevice winrt_device_{nullptr};
  wuc::Compositor compositor_{nullptr};
  wuc::ContainerVisual root_{nullptr};
  wgc::GraphicsCaptureItem item_{nullptr};
  wgc::Direct3D11CaptureFramePool pool_{nullptr};
  wgc::GraphicsCaptureSession session_{nullptr};
  winrt::event_token arrived_{};
  winrt::Windows::Graphics::SizeInt32 size_{};
  std::mutex lock_;
  winrt::com_ptr<ID3D11Texture2D> shared_;
  SharedFrame frame_;
};

}  // namespace

bool VisualCapture::Supported() {
  try {
    return wgc::GraphicsCaptureSession::IsSupported();
  } catch (winrt::hresult_error const&) {
    return false;
  }
}

std::shared_ptr<VisualCapture> VisualCapture::Create(
    IDXGIAdapter* adapter, std::function<void()> on_frame) {
  try {
    auto capture = std::make_shared<Capture>(std::move(on_frame));
    capture->Init(adapter);
    return capture;
  } catch (winrt::hresult_error const&) {
    return nullptr;
  }
}

}  // namespace slimm_youtube
