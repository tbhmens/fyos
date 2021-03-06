include "../shared/uintn.fy"

include "../fy-efi/efi.fy"
include "../fy-efi/protocols/file-system"
include "../fy-efi/protocols/loaded-image"
include "../fy-efi/protocols/graphics"
include "./efi/result"
include "./efi/efi_globals"
include "./efi/conin"
include "./efi/conout"
include "./efi/utils"

fun loaded_image_protocol(): EfiResult<*EFI_LOADED_IMAGE_PROTOCOL> {
	let loaded_image: *EFI_LOADED_IMAGE_PROTOCOL
	const status = boot_services.HandleProtocol(image_handle, &EFI_LOADED_IMAGE_PROTOCOL_GUID, &loaded_image)
	EfiResult(status, loaded_image)
}

fun load_root_image_dir(loaded_image: *EFI_LOADED_IMAGE_PROTOCOL): EfiResult<*EFI_FILE_PROTOCOL> {
	let file_system: *EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
	const status = boot_services.HandleProtocol(loaded_image.DeviceHandle, &EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID, &file_system)
	if(status != EFI_SUCCESS)
		return create EfiResult<*EFI_FILE_PROTOCOL> { status = status }
	let root: *EFI_FILE_PROTOCOL
	const status = file_system.OpenVolume(file_system, &root)
	EfiResult(status, root)
}

fun(*EFI_FILE_PROTOCOL) open(path: *CHAR16): EfiResult<*EFI_FILE_PROTOCOL> {
	let file: *EFI_FILE_PROTOCOL
	const status = this.Open(this, &file, path, EFI_FILE_MODE_READ, EFI_FILE_READ_ONLY)
	EfiResult(status, file)
}

// remember to efi_free the result
fun(*EFI_FILE_PROTOCOL) get_info(): EfiResult<*EFI_FILE_INFO> {
	let info_size: uintn
	this.GetInfo(this, &EFI_FILE_INFO_ID, &info_size, nullptr)
	const file_info: *EFI_FILE_INFO = efi_malloc(info_size) or {
		return create EfiResult<*EFI_FILE_INFO> { status = EFI_OUT_OF_RESOURCES } nullptr
	}
	const status = this.GetInfo(this, &EFI_FILE_INFO_ID, &info_size, file_info)
	EfiResult(status, file_info)
}

include "../shared/elf"
fun check_kernel_header(header: Elf64Header) {
	if(header.ident.magic[0] != 0x7f ||
	   header.ident.magic[1] != 'E' ||
	   header.ident.magic[2] != 'L' ||
	   header.ident.magic[3] != 'F') {
		println("Kernel file is not an ELF file"c 16)
		return false
	}
	if(header.ident.class != ELF_CLASS_64) {
		println("Kernel file is not 64-bit"c 16)
		return false
	}
	if(header.ident.endianness != ELF_LITTLE_ENDIAN) {
		println("Kernel file is not little-endian"c 16)
		return false
	}
	if(header.ident.version != ELF_VERSION_CURRENT || header.version != ELF_VERSION_CURRENT) {
		println("Kernel file is not version 1"c 16)
		return false
	}
	if(header.machine != ELF_MACHINE_X86_64) {
		println("Kernel file is not x86_64"c 16)
		return false
	}
	if(header.elf_type != ELF_TYPE_EXEC) {
		println("Kernel file is not an executable"c 16)
		return false
	}
	if(header.phentsize != sizeof(Elf64ProgramHeader)) {
		print("Kernel file has invalid program header size, expected"c 16)
		print_uint64(sizeof(Elf64ProgramHeader))
		print("but got"c 16)
		print_uint64(header.phentsize)
		newline()
		return false
	}
	true
}

include "../shared/framebuffer"
fun init_framebuffer(): EfiResult<Framebuffer> {
	let gop: *EFI_GRAPHICS_OUTPUT_PROTOCOL
	const status = boot_services.LocateProtocol(&EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID, null, &gop)
	if(status != EFI_SUCCESS) {
		println("Failed to locate graphics output protocol"c 16)
		return create EfiResult<Framebuffer> { status = status }
	}

	let info: *EFI_GRAPHICS_OUTPUT_MODE_INFORMATION
	let info_size: uintn
	let status = gop.QueryMode(gop, if(gop.Mode) gop.Mode.Mode else 0u, &info_size, &info)
	if(status == EFI_NOT_STARTED)
		status = gop.SetMode(gop, 0)
	const native_mode = gop.Mode.Mode
	const num_modes = gop.Mode.MaxMode
	let max_res: *EFI_GRAPHICS_OUTPUT_MODE_INFORMATION = info
	let max_res_mode: UINT32 = native_mode
	let max_res_size: UINT32 = info.HorizontalResolution * info.VerticalResolution
	for (let i: UINT32 = 0; i < num_modes; i += 1) {
		const status = gop.QueryMode(gop, i, &info_size, &info)
		if(status != EFI_SUCCESS) {
			print("Failed to query mode "c 16) print_uint64(i) newline()
			return create EfiResult<Framebuffer> { status = status }
		}
		print("Mode "c 16) print_uint64(i)
		if(i == native_mode) print(" (native)"c 16)
		print(": "c 16) print_uint64(info.HorizontalResolution)	print("x"c 16) print_uint64(info.VerticalResolution) newline()
		const res = info.HorizontalResolution * info.VerticalResolution
		if(res > max_res_size) {
			efi_free(max_res)
			max_res = info
			max_res_mode = i
			max_res_size = res null
		} else { efi_free(info) null }
	}
	const status = gop.SetMode(gop, max_res_mode)
	print("Using mode "c 16) print_uint64(max_res_mode) print(" with resolution "c 16) print_uint64(max_res.HorizontalResolution) print("x"c 16) print_uint64(max_res.VerticalResolution) println("."c 16)
	efi_free(max_res)
	if(status != EFI_SUCCESS) {
		println("Failed to set mode"c 16)
		return create EfiResult<Framebuffer> { status = status }
	}

	EfiResult(EFI_SUCCESS, create Framebuffer {
		pixels = gop.Mode.FrameBufferBase,
		size = gop.Mode.FrameBufferSize,
		width = gop.Mode.Info.HorizontalResolution,
		height = gop.Mode.Info.VerticalResolution,
		pixels_per_scanline = gop.Mode.Info.PixelsPerScanLine,
	})
}

include "../shared/psf2"
fun load_psf2_font(dir: *EFI_FILE_PROTOCOL, path: *CHAR16): EfiResult<PSF2_Font> {
	const file = dir.open(path).unwrap("Failed to open PSF2 font file"c 16)
	const info = file.get_info().unwrap("Failed to get info of PSF2 font file"c 16)
	const size = info.FileSize
	if(size < sizeof(PSF2_Header)) {
		println("PSF2 font file is too small for a valid PSF2 header"c 16)
		return create EfiResult<PSF2_Font> { status = EFI_INVALID_PARAMETER }
	}
	let header: PSF2_Header
	let header_size = sizeof(PSF2_Header)
	const status = file.Read(file, &header_size, &header)
	if(status != EFI_SUCCESS) {
		println("Failed to read PSF2 font file header"c 16)
		return create EfiResult<PSF2_Font> { status = status }
	}
	if(header.magic != PSF2_MAGIC) {
		println("PSF2 font file has invalid magic"c 16)
		return create EfiResult<PSF2_Font> { status = EFI_INVALID_PARAMETER }
	}
	if(header.headersize != sizeof(PSF2_Header)) {
		print("PSF2 font file has invalid header size, expected"c 16)
		print_uint64(sizeof(PSF2_Header))
		print("but got"c 16)
		print_uint64(header.headersize)
		newline()
		return create EfiResult<PSF2_Font> { status = EFI_INVALID_PARAMETER }
	}
	let glyph_size = header.glyphsize * header.numglyphs
	if(size < sizeof(PSF2_Header) + glyph_size) {
		println("PSF2 font file is too small to fit all glyphs"c 16)
		return create EfiResult<PSF2_Font> { status = EFI_INVALID_PARAMETER }
	}
	file.SetPosition(file, sizeof(PSF2_Header))
	const glyphs: *uint8 = efi_malloc(glyph_size) or {
		println("Failed to allocate memory for PSF2 font glyphs"c 16)
		return create EfiResult<PSF2_Font> { status = EFI_OUT_OF_RESOURCES } nullptr
	}
	const status = file.Read(file, &glyph_size, glyphs)
	if(status != EFI_SUCCESS) {
		println("Failed to read PSF2 font file glyphs"c 16)
		return create EfiResult<PSF2_Font> { status = status }
	}
	efi_free(info)
	EfiResult(EFI_SUCCESS, create PSF2_Font {
		header = header,
		glyphs = glyphs,
	})
}

include "../shared/bootinfo"
type KernelFunction = *fun cc(X8664SysV)(*BootInfo): EFI_STATUS
fun load_kernel(root_dir: *EFI_FILE_PROTOCOL): EfiResult<KernelFunction> {
	const kernel_file = root_dir.open("kernel.elf"c 16).unwrap("Failed to open kernel.elf"c 16)
	println("Opened kernel.elf"c 16)
	let header: Elf64Header
	{
		const file_info = kernel_file.get_info().unwrap("Failed to get kernel.elf info"c 16)
		let header_size = sizeof(Elf64Header)
		if(file_info.FileSize < header_size) {
			println("Kernel file is too small to fit elf header"c 16)
			return create EfiResult<KernelFunction> { status = EFI_ERR }
		}
		const status = kernel_file.Read(kernel_file, &header_size, &header)
		if(status != EFI_SUCCESS) {
			println("Failed to read header"c 16)
			return create EfiResult<KernelFunction> { status = status }
		}

		if(file_info.FileSize < header.phoff + header.phnum * header.phentsize) {
			println("Kernel file is too small to fit program headers. "c 16)
			print("Kernel file size: "c 16)
			print_uint64(file_info.FileSize) newline()
			print("Expected size: >="c 16)
			print_uint64(header.phoff + header.phnum * header.phentsize)
			newline()
			print("phoff: "c 16) print_uint64(header.phoff)
			print(", phnum: "c 16) print_uint64(header.phnum)
			print(", phentsize: "c 16) print_uint64(header.phentsize)
			newline()
			return create EfiResult<KernelFunction> { status = EFI_ERR }
		}
		efi_free(file_info)
	}
	if(!check_kernel_header(header)) return create EfiResult<KernelFunction> { status = EFI_INVALID_PARAMETER }
	println("Kernel file is valid"c 16)

	const program_headers: *Elf64ProgramHeader = efi_malloc(header.phnum * header.phentsize) or {
		println("Failed to allocate memory for program headers"c 16)
		return create EfiResult<KernelFunction> { status = EFI_OUT_OF_RESOURCES } nullptr
	}
	{
		let pos: uint64
		kernel_file.GetPosition(kernel_file, &pos)
		if(pos != header.phoff) {
			const status = kernel_file.SetPosition(kernel_file, header.phoff)
			if(status != EFI_SUCCESS) {
				println("Failed to set position in kernel file"c 16)
				return create EfiResult<KernelFunction> { status = status }
			}
		}
		let phsize = header.phnum * header.phentsize
		println("Reading program headers"c 16) print_uint64(phsize) newline()
		const status = kernel_file.Read(kernel_file, &phsize, program_headers)
		println("Read program headers"c 16)
		if(status != EFI_SUCCESS) {
			println("Failed to read kernel program headers"c 16)
			return create EfiResult<KernelFunction> { status = status }
		}
	}
	let total_size: uintn = 0
	for(let i: uint64 = 0; i < header.phnum; i += 1) {
		const pheader: *Elf64ProgramHeader = (program_headers as *uint8) + i * header.phentsize
		if(pheader.ptype == ELF_PT_LOAD) {
			const end: uintn = pheader.vaddr + pheader.memsz
			if(end > total_size) total_size = end
		}
	}

	const pages_to_alloc = (total_size + 0xfff) / 0x1000
	print("Allocating "c 16) print_uint64(pages_to_alloc) print(" pages ("c 16) print_uint64(total_size) print(" bytes) for the full kernel"c 16) newline()
	const kernel_address: *uint8 = {
		let pages: *uint8
		const status = boot_services.AllocatePages(AllocateAnyPages, EfiLoaderData, pages_to_alloc, &pages)
		if(status != EFI_SUCCESS) {
			println("Failed to allocate memory for kernel"c 16)
			return create EfiResult<KernelFunction> { status = status }
		}
		pages
	}


	for(let i: uint64 = 0; i < header.phnum; i += 1) {
		const pheader: *Elf64ProgramHeader = (program_headers as *uint8) + i * header.phentsize
		if(pheader.ptype == ELF_PT_LOAD) {
			const status = kernel_file.SetPosition(kernel_file, pheader.offset)
			if(status != EFI_SUCCESS) {
				println("Failed to set position in kernel file"c 16)
				return create EfiResult<KernelFunction> { status = status }
			}
			const mem_pos = kernel_address + pheader.vaddr
			const status = kernel_file.Read(kernel_file, &pheader.filesz, mem_pos)
			if(status != EFI_SUCCESS) {
				println("Failed to read segment"c 16)
				return create EfiResult<KernelFunction> { status = status }
			}
		}
	}

	kernel_file.Close(kernel_file)
	println("Kernel loaded"c 16)
	create EfiResult<KernelFunction> {
		status = EFI_SUCCESS,
		value = kernel_address + header.entry,
	}
}

fun efi_main(ih: EFI_HANDLE, st: *EFI_SYSTEM_TABLE): EFI_STATUS {
	conout.clear_screen()
	const loaded_image = loaded_image_protocol().unwrap("Failed to get loaded image protocol"c 16)
	const root_dir = load_root_image_dir(loaded_image).unwrap("Failed to get root directory of image"c 16)

	const framebuffer = {
		const framebuffer: Framebuffer = init_framebuffer().unwrap("Failed to initialize framebuffer"c 16)
		println("Framebuffer initialized"c 16)
		print("Framebuffer pixel base: "c 16) print_hex(framebuffer.pixels) newline()
		print("Framebuffer size: "c 16) print_uint64(framebuffer.size) newline()
		print("Framebuffer resolution: "c 16) print_uint64(framebuffer.width) print("x"c 16) print_uint64(framebuffer.height) newline()
		print("Framebuffer pixels per scanline: "c 16) print_uint64(framebuffer.pixels_per_scanline) newline()
		framebuffer
	}

	const font = {
		println("Loading PSF2 font..."c 16)
		const font = load_psf2_font(root_dir, "font.psf"c 16).unwrap("Failed to load PSF2 font"c 16)
		println("Loaded PSF2 font"c 16)
		print("Font character resolution: "c 16) print_uint64(font.header.width) print("x"c 16) print_uint64(font.header.height) newline()
		font
	}

	const kernel_entry: KernelFunction = load_kernel(root_dir).unwrap("Failed to load kernel"c 16)
	print("Kernel entry point: "c 16) print_hex(kernel_entry) newline()

	println("Exiting boot services..."c 16)
	let memory_map_size: uintn = 0
	let memory_map: *EFI_MEMORY_DESCRIPTOR = nullptr
	let memory_map_key: uintn = 0
	let descriptor_size: uintn = 0
	let descriptor_version: UINT32 = 0
	{
		const status = boot_services.GetMemoryMap(&memory_map_size, memory_map, &memory_map_key, &descriptor_size, &descriptor_version)
		if(status != EFI_BUFFER_TOO_SMALL) {
			println("Failed to get memory map size"c 16)
			return status
		}
		memory_map_size += descriptor_size * 2
		memory_map = efi_malloc(memory_map_size) or {
			println("Failed to allocate memory for memory map"c 16)
			return EFI_OUT_OF_RESOURCES nullptr
		}
		const status = boot_services.GetMemoryMap(&memory_map_size, memory_map, &memory_map_key, &descriptor_size, &descriptor_version)
		if(status != EFI_SUCCESS) {
			println("Failed to get memory map"c 16)
			return status
		}
	}
	const status = boot_services.ExitBootServices(image_handle, memory_map_key)
	if(status != EFI_SUCCESS) {
		println("Failed to exit boot services"c 16)
		return status
	}

	let boot_info = create BootInfo {
		framebuffer = framebuffer,
		font = font,
		memmap = create MemoryMap {
			descriptors = memory_map,
			full_size = memory_map_size,
			descriptor_size = descriptor_size,
			page_count = page_count(memory_map, memory_map_size, descriptor_size),
		},
		runtime_services = runtime_services,
	}

	const kernel_ret = kernel_entry(&boot_info)
	kernel_ret
}

fun main cc(EFIAPI) (ih: EFI_HANDLE, st: *EFI_SYSTEM_TABLE): EFI_STATUS {
	init_efi_globals(ih, st)
	const status = efi_main(ih, st)
	shutdown(status)
	status
}

fun __chkstk always_compile(true)() null
