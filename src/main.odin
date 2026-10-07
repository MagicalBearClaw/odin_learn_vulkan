package main

import "core:log"
import "core:fmt"
import "core:flags"
import "core:os"
import "core:strings"
import "core:slice"
import "base:runtime"

import "vendor:sdl3"

import "vendor:vulkan"

Vulkan_Validation_Layer :: "VK_LAYER_KHRONOS_validation"

Application_Options :: struct {
	width: i32 `usage: "Width of the window"`,
	height: i32 `usage: "Height of the window"`,
	validation: bool `usage: "Whether to use vk validation layers"`,
	frame_limit: u64 `usage: "Maximum frames per second"`,
}

Application :: struct {
	_options: ^Application_Options,
	_name: string,
	_window: ^sdl3.Window,
	_surface: vulkan.SurfaceKHR,
	_ctx: runtime.Context,
	_instance: vulkan.Instance,
	_debug_messenger: vulkan.DebugUtilsMessengerEXT
}

SDL3_Error :: struct {
	code: i32,
	message: string,
}

Vulkan_Error :: enum {
	SUCCESS = 0,
	INCOMPATIBLE_PHYSICAL_DEVICE
}

Application_Error :: union {
	SDL3_Error,
	vulkan.Result,
	Vulkan_Error
}

available_layer :: proc(layer: string) -> (is_layer_available: bool, result: vulkan.Result) {

	layer_count : u32 = 0
	layer_properties : []vulkan.LayerProperties
	vulkan.EnumerateInstanceLayerProperties(&layer_count, nil) or_return
	layer_properties = make([]vulkan.LayerProperties, layer_count, context.temp_allocator)
	vulkan.EnumerateInstanceLayerProperties(&layer_count, raw_data(layer_properties)) or_return

	layer_to_check := layer
	context.user_ptr = &layer_to_check

	return slice.any_of_proc(layer_properties, proc(x: vulkan.LayerProperties) -> bool {
		layer_name_cstr := x.layerName
		layer_name := strings.truncate_to_byte(string(layer_name_cstr[:]), 0)
		return layer_name == (^string)(context.user_ptr)^
	}), vulkan.Result.SUCCESS
}

available_instance_extensions :: proc(extension: string) -> (is_extension_available: bool, result: vulkan.Result) {

	instance_extension_count : u32 = 0
	instance_extensions : []vulkan.ExtensionProperties
	vulkan.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil) or_return
	instance_extensions = make([]vulkan.ExtensionProperties, instance_extension_count, context.temp_allocator)
	vulkan.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, raw_data(instance_extensions)) or_return

	extension_to_check := extension
	context.user_ptr = &extension_to_check

	return slice.any_of_proc(instance_extensions, proc(x: vulkan.ExtensionProperties) -> bool {
		extension_name_cstr := x.extensionName
		extension_name := strings.truncate_to_byte(string(extension_name_cstr[:]), 0)
		return extension_name == (^string)(context.user_ptr)^
	}), vulkan.Result.SUCCESS
}

device_support_extensions :: proc(physical_device: vulkan.PhysicalDevice, required_extensions: []string) -> (is_device_extension_available: bool, result: vulkan.Result) {
	deivce_extension_count : u32 = 0
	deivce_extensions : []vulkan.ExtensionProperties
	vulkan.EnumerateDeviceExtensionProperties(physical_device, nil,&deivce_extension_count, nil) or_return
	deivce_extensions = make([]vulkan.ExtensionProperties, deivce_extension_count, context.temp_allocator)
	vulkan.EnumerateDeviceExtensionProperties(physical_device, nil, &deivce_extension_count, raw_data(deivce_extensions)) or_return

	context.user_ptr = &deivce_extensions

	return slice.all_of_proc(required_extensions, proc(re: string) -> bool {
		device_ext := (^[]vulkan.ExtensionProperties)(context.user_ptr)^
		re := re
		context.user_ptr = &re
		return slice.any_of_proc(device_ext, proc(ep: vulkan.ExtensionProperties) -> bool {
			re := (^string)(context.user_ptr)^
			ext_name_cstr := ep.extensionName
			ext_name := strings.truncate_to_byte(string(ext_name_cstr[:]), 0)
			return re == ext_name
		})
	}), vulkan.Result.SUCCESS
}

find_universal_queue_family :: proc(physical_device: vulkan.PhysicalDevice, surface: vulkan.SurfaceKHR) -> Maybe(u32) {

	qf_count : u32 = 0
	vulkan.GetPhysicalDeviceQueueFamilyProperties(physical_device, &qf_count, nil)
	qfs := make([]vulkan.QueueFamilyProperties, qf_count, context.temp_allocator)
	vulkan.GetPhysicalDeviceQueueFamilyProperties(physical_device, &qf_count, raw_data(qfs))

	for i in 0..<qf_count {
		wanted : vulkan.QueueFlags = { vulkan.QueueFlag.GRAPHICS, vulkan.QueueFlag.COMPUTE}
		if wanted >= qfs[i].queueFlags {
			continue
		}

		can_present :b32 = false
		vulkan.GetPhysicalDeviceSurfaceSupportKHR(physical_device, i, surface, &can_present)
		if can_present {
			return i
		}
	}

	return nil
}

score_physical_device ::proc(device_props: vulkan.PhysicalDeviceProperties) -> u32 {
	switch device_props.deviceType {
		case vulkan.PhysicalDeviceType.DISCRETE_GPU: return 3
		case vulkan.PhysicalDeviceType.INTEGRATED_GPU: return 2
		case vulkan.PhysicalDeviceType.VIRTUAL_GPU: return 1
		case vulkan.PhysicalDeviceType.OTHER:
		case vulkan.PhysicalDeviceType.CPU: return 0
	}

	return 0
}

device_type_name :: proc(device_type: vulkan.PhysicalDeviceType) -> string {
	    switch device_type {
        case vulkan.PhysicalDeviceType.DISCRETE_GPU: return "discrete GPU"
        case vulkan.PhysicalDeviceType.INTEGRATED_GPU: return "integrated GPU"
        case vulkan.PhysicalDeviceType.VIRTUAL_GPU: return "virtual GPU"
        case vulkan.PhysicalDeviceType.CPU: return "CPU"
		case vulkan.PhysicalDeviceType.OTHER: return "Other"
    }

	return "Other"
}

Physical_Device :: struct {
	queue_family : u32,
	physical_device : vulkan.PhysicalDevice,
	properties : vulkan.PhysicalDeviceProperties,
}

select_physical_device :: proc(instance: vulkan.Instance, surface: vulkan.SurfaceKHR) -> (physical_device: Physical_Device, application_error: Application_Error){

	count : u32 = 0
	vulkan.EnumeratePhysicalDevices(instance, &count, nil) or_return
	physical_devices := make([]vulkan.PhysicalDevice, count, context.temp_allocator)
	vulkan.EnumeratePhysicalDevices(instance, &count, raw_data(physical_devices)) or_return

	best_score : u32 = 0
	gpu : vulkan.PhysicalDevice
	gpu_props : vulkan.PhysicalDeviceProperties
	qf : u32 = 0
	for candidate in physical_devices {
		props : vulkan.PhysicalDeviceProperties
		vulkan.GetPhysicalDeviceProperties(candidate, &props)
		log.info("", props.deviceName, props, device_type_name(props.deviceType))

		if props.apiVersion < vulkan.API_VERSION_1_3 {
			continue
		}

		is_device_supported := device_support_extensions(candidate, vulkan.KHR_SWAPCHAIN_EXTENSION_NAME) or_return
		if !is_device_supported {
			continue
		}

		family := find_universal_queue_family(candidate, surface)
		if family == nil {
			continue
		}

		score : u32 = score_physical_device(props)
		if score > best_score {
			best_score = score
			gpu = candidate
			gpu_props = props
			qf = family.?
		}
	}

	if gpu == nil {
		return {}, Vulkan_Error.INCOMPATIBLE_PHYSICAL_DEVICE
	}

	return Physical_Device {
		physical_device = gpu,
		properties = gpu_props,
		queue_family = qf
	}, nil
}

create_device :: proc(queue_family: u32) -> vulkan.Device {
	priority : f32 = 1.0

	queue_info : vulkan.DeviceQueueCreateInfo = {
		sType = vulkan.StructureType.DEVICE_QUEUE_CREATE_INFO,
		pNext = nil,
		flags = {},
		queueFamilyIndex = queue_family,
		queueCount = 1,
		pQueuePriorities = &priority
	}

	features_13 : vulkan.PhysicalDeviceVulkan13Features = {
		sType = vulkan.StructureType.PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = true,
		dynamicRendering = true
	}

	features_12 : vulkan.PhysicalDeviceVulkan12Features = {
		sType = vulkan.StructureType.PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &features_13,
		bufferDeviceAddress = true,
		descriptorIndexing = true
	}

	features_2 : vulkan.PhysicalDeviceFeatures2 = {
		sType = vulkan.StructureType.PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &features_12,
	}

	features_2.features.samplerAnisotropy = true
}


create_surface :: proc(window: ^sdl3.Window, instance: vulkan.Instance) -> (vulkan.SurfaceKHR, Application_Error) {
	surface : vulkan.SurfaceKHR = {}
	surface_created := sdl3.Vulkan_CreateSurface(window, instance, nil, &surface)
	if !surface_created {
		return surface, SDL3_Error {
			code = -1,
			message = string(sdl3.GetError())
		}
	}

	return surface, nil
}

pixel_extent :: proc(app : ^Application) -> vulkan.Extent2D {
	
	width : i32 = 0
	height : i32 = 0

	sdl3.GetWindowSizeInPixels(app._window, &width, &height)
	return {
		width = u32(width),
		height = u32(height)
	}
}

is_minimized :: proc(window: ^sdl3.Window) -> bool {
	return sdl3.WindowFlag.MINIMIZED in sdl3.GetWindowFlags(window)
}

destroy_surface :: proc(instance: vulkan.Instance, surface: vulkan.SurfaceKHR) {
	sdl3.Vulkan_DestroySurface(instance, surface, nil)
}

required_instance_extensions :: proc(app: ^Application) -> []cstring {
	count :u32 = 0	
	ext_names_cs := sdl3.Vulkan_GetInstanceExtensions(&count)
	return ext_names_cs[:count]
}


make_application :: proc(options: ^Application_Options, name: string) -> (application: ^Application, application_error: Application_Error) {
	app := new(Application)
	app._options = options
	app._name = name

	init_applciation(app) or_return

	return app, nil
}


/////////////////////////////////////////////////////////
/// Debug
/////////////////////////////////////////////////////////

debug_callback :: proc "system" (severity : vulkan.DebugUtilsMessageSeverityFlagsEXT, types : vulkan.DebugUtilsMessageTypeFlagsEXT,
data : ^vulkan.DebugUtilsMessengerCallbackDataEXT, user_data: rawptr) -> b32 {

	app := (^Application)(user_data)
    context = app._ctx
	if vulkan.DebugUtilsMessageSeverityFlagEXT.ERROR in severity {
		log.error("[Vulkan Error]", data.pMessage)
	}
	else if vulkan.DebugUtilsMessageSeverityFlagEXT.WARNING in severity {
		log.warn("[Vulkan Warn]", data.pMessage)
	}
	else {
		log.debug("[Vulkan Debug]", data.pMessage)
	}

	return false
}

create_debug_messenger_info :: proc(app: ^Application) -> vulkan.DebugUtilsMessengerCreateInfoEXT {

	return vulkan.DebugUtilsMessengerCreateInfoEXT {
		sType = vulkan.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		pNext = nil,
		flags = {},
		messageSeverity = { .ERROR, .WARNING},
		messageType = { .GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
		pUserData = app
	}
}



init_applciation :: proc(app: ^Application) -> Application_Error {

	if !sdl3.Init(sdl3.INIT_VIDEO) {
		return SDL3_Error {
			code = -1,
			message = string(sdl3.GetError())
		}
	}

	name := strings.clone_to_cstring(app._name)
	app._window = sdl3.CreateWindow(name, app._options.width, app._options.height, {.VULKAN})

	if app._window == nil {
		return SDL3_Error {
			code = -1,
			message = string(sdl3.GetError())
		}
	}

	return init_vulkan(app)
}

init_vulkan :: proc(app: ^Application) -> Application_Error {

	get_proc := sdl3.Vulkan_GetVkGetInstanceProcAddr()
	if get_proc == nil {
		return SDL3_Error{code = -1, message = string(sdl3.GetError())}
	}
	vulkan.load_proc_addresses_global(rawptr(get_proc))

	app_info := vulkan.ApplicationInfo {
		sType = vulkan.StructureType.APPLICATION_INFO,
		pNext = nil,
		pApplicationName = strings.clone_to_cstring(app._name),
		applicationVersion = vulkan.MAKE_VERSION(0, 1, 0),
		pEngineName = "Odin Vulkan Engine",
		engineVersion = vulkan.MAKE_VERSION(0, 1, 0),
		apiVersion = vulkan.API_VERSION_1_3
	}

	extensions := make([dynamic]cstring, 0, 4, context.temp_allocator) 
	required_extensions := required_instance_extensions(app)

	append(&extensions, ..required_extensions)
	append(&extensions, vulkan.KHR_SWAPCHAIN_EXTENSION_NAME)

	is_layer_available := available_layer(Vulkan_Validation_Layer) or_return

	if app._options.validation && !is_layer_available  {
		log.warn(            """
									Validation layers were requested but {} is not installed. Install the
									Vulkan SDK or your distribution's validation-layers package: running
									these samples without validation hides real bugs.
									""")
	}

	debug_utils_enabled := available_instance_extensions(vulkan.EXT_DEBUG_UTILS_EXTENSION_NAME) or_return
	if(debug_utils_enabled) {
		append(&extensions, vulkan.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	layers := make([dynamic]cstring, 0, 4, context.temp_allocator) 
	if app._options.validation {
		append(&layers, Vulkan_Validation_Layer)
	}

	debug_messenger_info := create_debug_messenger_info(app)

	instance_ci := vulkan.InstanceCreateInfo {
		sType = vulkan.StructureType.INSTANCE_CREATE_INFO,
		pNext = (app._options.validation && debug_utils_enabled) ? &debug_messenger_info : nil,
		flags = {},
		pApplicationInfo = &app_info,
		enabledLayerCount = u32(len(layers)),
		ppEnabledLayerNames = raw_data(layers),
		enabledExtensionCount = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions)
	}

	vulkan.CreateInstance(&instance_ci, nil, &app._instance) or_return
	vulkan.load_proc_addresses_instance(app._instance)

	if debug_utils_enabled && app._options.validation {
		init_debug_messenger(app) or_return
	}

	return nil
}

init_debug_messenger :: proc(app: ^Application) -> vulkan.Result {
	debug_messenger_info := create_debug_messenger_info(app)
	vulkan.CreateDebugUtilsMessengerEXT(app._instance, &debug_messenger_info, nil, &app._debug_messenger) or_return
	return vulkan.Result.SUCCESS
}


destroy_application :: proc(app: ^Application) {

	vulkan.DestroyDebugUtilsMessengerEXT(app._instance, app._debug_messenger, nil)
	vulkan.DestroyInstance(app._instance, nil)
	sdl3.DestroyWindow(app._window)
	free(app)
	sdl3.Quit()
}

run_application :: proc(app: ^Application) -> Application_Error {

	frames : u64 = 0

	running : bool = true

	for running {
		event : sdl3.Event
		for sdl3.PollEvent(&event) {
			#partial switch (event.type) {
				case .QUIT:
				case .WINDOW_CLOSE_REQUESTED:
					{
						running = false
						break
					}
				case .KEY_DOWN : {
					if event.key.key == sdl3.K_ESCAPE {
						running = false
					}
					break
				}
				case .WINDOW_PIXEL_SIZE_CHANGED : {
					break
				}
			}
		}

		frames += 1
	}
	return nil
}


main :: proc() {
	options := Application_Options{
		width = 800,
		height = 600,
		validation = true,
		frame_limit = 60
	}

	flags.parse_or_exit(&options, os.args, .Odin)

    context.logger = log.create_console_logger()
    
	defer log.destroy_console_logger(context.logger)

	app, err := make_application(&options, "test sdl3 app")

	ec : i32 = 0

	if err != nil {
		switch e in err {
			case SDL3_Error:
				log.error(e.message)
				ec = e.code
				break
			case vulkan.Result:
				log.error("Vulkan Error encountered, shutting down application")
				ec = i32(e)
		}
	}

	err = run_application(app)

	if err != nil {
		switch e in err {
			case SDL3_Error:
				log.error(e.message)
				ec = e.code
				break
			case vulkan.Result:
				log.error("Vulkan Error encountered, shutting down application")
				ec = i32(e)
		}
	}

	defer {
		destroy_application(app)
		os.exit(int(ec))
	}
}