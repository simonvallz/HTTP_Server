#scope_module

create_context :: () -> *SSL_CTX {
    method := TLS_server_method();
    ctx := SSL_CTX_new(method);

    if !ctx {
        error := ERR_get_error();

        error_string: string;
        error_string.data = ERR_error_string(error, null);
        error_string.count = c_style_strlen(error_string.data);

        print("SSL_CTX_new: [%] %\n", error, error_string);
        exit(1);
    }

    return ctx;
}

configure_context :: (ctx: *SSL_CTX, certificate_file: string, private_key_file: string) {
    if SSL_CTX_use_certificate_file(ctx, temp_c_string(certificate_file), SSL_FILETYPE_PEM) <= 0 {
        error := ERR_get_error();

        error_string: string;
        error_string.data = ERR_error_string(error, null);
        error_string.count = c_style_strlen(error_string.data);

        print("SSL_CTX_use_certificate_file: [%] %\n", error, error_string);
        exit(1);
    }

    if SSL_CTX_use_PrivateKey_file(ctx, temp_c_string(private_key_file), SSL_FILETYPE_PEM) <= 0 {
        error := ERR_get_error();

        error_string: string;
        error_string.data = ERR_error_string(error, null);
        error_string.count = c_style_strlen(error_string.data);

        print("SSL_CTX_use_PrivateKey_file: [%] %\n", error, error_string);
        exit(1);
    }
}

SSL        :: struct {}
SSL_CTX    :: struct {}
SSL_METHOD :: struct {}

SSL_CTX_new :: (method: *SSL_METHOD) -> *SSL_CTX #foreign libssl;

TLS_server_method :: () -> *SSL_METHOD #foreign libssl;

SSL_new    :: (ctx: *SSL_CTX) -> *SSL     #foreign libssl;
SSL_set_fd :: (ssl: *SSL, fd: s32) -> s32 #foreign libssl;

SSL_accept :: (ssl: *SSL) -> s32                                #foreign libssl;
SSL_read   :: (ssl: *SSL, buffer: *u8, buffer_size: s32) -> s32 #foreign libssl;
SSL_write  :: (ssl: *SSL, buffer: *u8, buffer_size: s32) -> s32 #foreign libssl;

SSL_CTX_use_certificate_file :: (ctx: *SSL_CTX, file: *u8, type: s32) -> s32 #foreign libssl;
SSL_CTX_use_PrivateKey_file  :: (ctx: *SSL_CTX, file: *u8, type: s32) -> s32 #foreign libssl;

SSL_shutdown :: (ssl: *SSL) -> s32 #foreign libssl;
SSL_free     :: (ssl: *SSL)        #foreign libssl;
SSL_CTX_free :: (ctx: *SSL_CTX)    #foreign libssl;

SSL_FILETYPE_PEM :: 1;

SSL_get_error    :: (ssl: *SSL, code: s32) -> s32    #foreign libssl;
ERR_get_error    :: () -> u64                        #foreign libssl;
ERR_error_string :: (error: u64, buffer: *u8) -> *u8 #foreign libssl;

SSL_ERROR_WANT_READ  :: 2;
SSL_ERROR_WANT_WRITE :: 3;

libssl    :: #system_library "libssl";
libcrypto :: #system_library,link_always "libcrypto";