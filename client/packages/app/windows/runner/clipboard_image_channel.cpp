#include "clipboard_image_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <utility>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

struct Bitmap {
  UINT width = 0;
  UINT height = 0;
  std::vector<BYTE> bgra;  // top-down
};

// Decodes the PNG with WIC, which ships with Windows.
bool DecodePng(const std::vector<uint8_t>& png, Bitmap* out) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory)))) {
    return false;
  }
  ComPtr<IWICStream> stream;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(
          const_cast<BYTE*>(png.data()), static_cast<DWORD>(png.size())))) {
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom)) ||
      FAILED(converter->GetSize(&out->width, &out->height)) ||
      out->width == 0 || out->height == 0) {
    return false;
  }
  out->bgra.resize(static_cast<size_t>(out->width) * out->height * 4);
  return SUCCEEDED(converter->CopyPixels(
      nullptr, out->width * 4, static_cast<UINT>(out->bgra.size()),
      out->bgra.data()));
}

HGLOBAL AllocCopy(const void* data, size_t size) {
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, size);
  if (handle == nullptr) return nullptr;
  void* dest = GlobalLock(handle);
  if (dest == nullptr) {
    GlobalFree(handle);
    return nullptr;
  }
  std::memcpy(dest, data, size);
  GlobalUnlock(handle);
  return handle;
}

// A bottom-up V5 DIB with an alpha mask; Windows derives CF_DIB from it.
HGLOBAL MakeDib(const Bitmap& bitmap) {
  const size_t row = static_cast<size_t>(bitmap.width) * 4;
  std::vector<BYTE> blob(sizeof(BITMAPV5HEADER) + row * bitmap.height);
  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(BITMAPV5HEADER);
  header.bV5Width = static_cast<LONG>(bitmap.width);
  header.bV5Height = static_cast<LONG>(bitmap.height);
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5SizeImage = static_cast<DWORD>(row * bitmap.height);
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;
  header.bV5CSType = LCS_sRGB;
  header.bV5Intent = LCS_GM_IMAGES;
  std::memcpy(blob.data(), &header, sizeof(header));
  for (UINT y = 0; y < bitmap.height; ++y) {
    std::memcpy(blob.data() + sizeof(header) + row * y,
                bitmap.bgra.data() + row * (bitmap.height - 1 - y), row);
  }
  return AllocCopy(blob.data(), blob.size());
}

bool WriteClipboard(HWND owner, const std::vector<uint8_t>& png) {
  Bitmap bitmap;
  if (!DecodePng(png, &bitmap)) return false;
  HGLOBAL dib = MakeDib(bitmap);
  HGLOBAL png_copy = AllocCopy(png.data(), png.size());
  if (dib == nullptr || png_copy == nullptr || !OpenClipboard(owner)) {
    if (dib != nullptr) GlobalFree(dib);
    if (png_copy != nullptr) GlobalFree(png_copy);
    return false;
  }
  EmptyClipboard();
  // The clipboard owns each handle once SetClipboardData accepts it.
  bool ok = SetClipboardData(CF_DIBV5, dib) != nullptr;
  if (!ok) GlobalFree(dib);
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_format == 0 || SetClipboardData(png_format, png_copy) == nullptr) {
    GlobalFree(png_copy);
  }
  CloseClipboard();
  return ok;
}

bool HasClipboardImage() {
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  return (png_format != 0 && IsClipboardFormatAvailable(png_format)) ||
         IsClipboardFormatAvailable(CF_DIBV5) ||
         IsClipboardFormatAvailable(CF_DIB);
}

std::vector<uint8_t> CopyGlobal(HANDLE handle) {
  std::vector<uint8_t> bytes;
  if (handle == nullptr) return bytes;
  const SIZE_T size = GlobalSize(handle);
  const void* data = GlobalLock(handle);
  if (data != nullptr && size > 0) {
    bytes.assign(static_cast<const uint8_t*>(data),
                 static_cast<const uint8_t*>(data) + size);
  }
  if (data != nullptr) GlobalUnlock(handle);
  return bytes;
}

// A packed DIB with a BITMAPFILEHEADER in front is a .bmp file, which the
// Dart side decodes and re-encodes as PNG; that keeps this side free of an
// encoder.
std::vector<uint8_t> DibToBmp(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return {};
  BITMAPINFOHEADER header;
  std::memcpy(&header, dib.data(), sizeof(header));
  DWORD palette = header.biClrUsed;
  if (palette == 0 && header.biBitCount <= 8) palette = 1u << header.biBitCount;
  DWORD masks = 0;
  if (header.biSize == sizeof(BITMAPINFOHEADER)) {
    if (header.biCompression == BI_BITFIELDS) {
      masks = 3 * sizeof(DWORD);
    } else if (header.biCompression == 6 /* BI_ALPHABITFIELDS */) {
      masks = 4 * sizeof(DWORD);
    }
  }
  const DWORD offset = sizeof(BITMAPFILEHEADER) + header.biSize + masks +
                       palette * sizeof(RGBQUAD);
  if (offset > sizeof(BITMAPFILEHEADER) + dib.size()) return {};
  BITMAPFILEHEADER file = {};
  file.bfType = 0x4D42;  // "BM"
  file.bfSize = static_cast<DWORD>(sizeof(file) + dib.size());
  file.bfOffBits = offset;
  std::vector<uint8_t> bmp(sizeof(file));
  std::memcpy(bmp.data(), &file, sizeof(file));
  bmp.insert(bmp.end(), dib.begin(), dib.end());
  // GDI 32-bpp BI_RGB captures leave the fourth byte zero; opaque it when every pixel has zero alpha.
  if (header.biBitCount == 32 && header.biCompression == BI_RGB &&
      bmp.size() > offset + 3) {
    bool any_alpha = false;
    for (size_t i = offset + 3; i < bmp.size(); i += 4) {
      if (bmp[i] != 0) {
        any_alpha = true;
        break;
      }
    }
    if (!any_alpha) {
      for (size_t i = offset + 3; i < bmp.size(); i += 4) {
        bmp[i] = 0xFF;
      }
    }
  }
  return bmp;
}

// The clipboard image as PNG when an app offered one, else as a .bmp; empty
// when the clipboard holds no image or could not be opened.
std::vector<uint8_t> ReadClipboardImage(HWND owner) {
  std::vector<uint8_t> bytes;
  if (!OpenClipboard(owner)) return bytes;
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
    bytes = CopyGlobal(GetClipboardData(png_format));
  }
  if (bytes.empty() && IsClipboardFormatAvailable(CF_DIBV5)) {
    bytes = DibToBmp(CopyGlobal(GetClipboardData(CF_DIBV5)));
  }
  if (bytes.empty() && IsClipboardFormatAvailable(CF_DIB)) {
    bytes = DibToBmp(CopyGlobal(GetClipboardData(CF_DIB)));
  }
  CloseClipboard();
  return bytes;
}

}  // namespace

void RegisterClipboardImageChannel(flutter::BinaryMessenger* messenger,
                                   HWND owner) {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "top.npcserver.slimm/clipboard_image",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [owner](const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result) {
        if (call.method_name() == "hasImage") {
          result->Success(flutter::EncodableValue(HasClipboardImage()));
          return;
        }
        if (call.method_name() == "readImage") {
          std::vector<uint8_t> image = ReadClipboardImage(owner);
          if (image.empty()) {
            result->Success();
          } else {
            result->Success(flutter::EncodableValue(std::move(image)));
          }
          return;
        }
        if (call.method_name() != "writeImage") {
          result->NotImplemented();
          return;
        }
        const auto* png =
            call.arguments() == nullptr
                ? nullptr
                : std::get_if<std::vector<uint8_t>>(call.arguments());
        if (png == nullptr || !WriteClipboard(owner, *png)) {
          result->Error("write_failed", "The image could not be copied.");
          return;
        }
        result->Success();
      });
}
