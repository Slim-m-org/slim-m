# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Regenerates client/packages/app/assets/icons/tray_icon.ico from packaging/linux/icons (needs Pillow).

Windows tray_manager only loads .ico files. Run from the repo root: python3 scripts/make-tray-ico.py"""
import io, struct, sys
from PIL import Image
src='packaging/linux/icons/top.npcserver.slimm-%d.png'
imgs=[]
for n in (16,20,24,32,48):
    try: im=Image.open(src%n).convert('RGBA')
    except FileNotFoundError: im=Image.open(src%48).convert('RGBA').resize((n,n),Image.LANCZOS)
    b=io.BytesIO(); im.save(b,'PNG'); imgs.append((n,b.getvalue()))
out=struct.pack('<HHH',0,1,len(imgs)); off=6+16*len(imgs); data=b''
for n,d in imgs:
    out+=struct.pack('<BBBBHHII',n,n,0,0,1,32,len(d),off+len(data)); data+=d
open("client/packages/app/assets/icons/tray_icon.ico",'wb').write(out+data)
