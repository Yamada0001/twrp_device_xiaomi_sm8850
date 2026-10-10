/* Read-only integration probe. Never invokes Weaver read or write. */
#include <android/binder_ibinder.h>
#include <android/binder_parcel.h>
#include <android/binder_status.h>
#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <unistd.h>

static void* on_create(void* args) { return args; }
static void on_destroy(void* data) { (void)data; }
static binder_status_t on_transact(AIBinder* binder, transaction_code_t code,
                                  const AParcel* in, AParcel* out) {
    (void)binder;
    (void)code;
    (void)in;
    (void)out;
    return STATUS_UNKNOWN_TRANSACTION;
}

int main(void) {
    /* Servicemanager helpers are platform exports, outside the public NDK. */
    void* library = dlopen("libbinder_ndk.so", RTLD_NOW | RTLD_LOCAL);
    AIBinder* (*check_service)(const char*) = library
        ? (AIBinder* (*)(const char*))dlsym(library, "AServiceManager_checkService")
        : NULL;
    if (!check_service) {
        fprintf(stderr, "Service lookup unavailable: %s\n", dlerror());
        return 1;
    }
    AIBinder* binder = check_service("android.hardware.weaver.IWeaver/default");
    if (!binder) {
        fprintf(stderr, "Weaver service is absent\n");
        return 1;
    }
    AIBinder_Class* clazz = AIBinder_Class_define("android.hardware.weaver.IWeaver",
                                                on_create, on_destroy, on_transact);
    if (!clazz || !AIBinder_associateClass(binder, clazz)) {
        fprintf(stderr, "Weaver interface association failed\n");
        AIBinder_decStrong(binder);
        return 1;
    }
    /* A blocked vendor HAL must not hang this diagnostic indefinitely. */
    alarm(20);
    AParcel* request = NULL;
    AParcel* reply = NULL;
    binder_status_t status = AIBinder_prepareTransaction(binder, &request);
    if (status == STATUS_OK) {
        /* getConfig is the first method in the stable IWeaver AIDL. */
        status = AIBinder_transact(binder, FIRST_CALL_TRANSACTION, &request, &reply, 0);
    }
    AStatus* result = NULL;
    if (status == STATUS_OK) status = AParcel_readStatusHeader(reply, &result);
    int exit_code = 1;
    if (status != STATUS_OK) {
        fprintf(stderr, "getConfig Binder error: %d\n", status);
    } else if (!AStatus_isOk(result)) {
        fprintf(stderr, "getConfig exception=%d service_error=%d message=%s\n",
                AStatus_getExceptionCode(result), AStatus_getServiceSpecificError(result),
                AStatus_getMessage(result));
    } else {
        int32_t present = 0, size = 0, slots = 0, key_size = 0, value_size = 0;
        status = AParcel_readInt32(reply, &present);
        if (status == STATUS_OK && present == 1) status = AParcel_readInt32(reply, &size);
        if (status == STATUS_OK && present == 1 && size >= 16) {
            status = AParcel_readInt32(reply, &slots);
            if (status == STATUS_OK) status = AParcel_readInt32(reply, &key_size);
            if (status == STATUS_OK) status = AParcel_readInt32(reply, &value_size);
            if (status == STATUS_OK && slots > 0 && key_size > 0 && value_size > 0) {
                printf("Weaver configuration ready: slots=%" PRId32
                       " keySize=%" PRId32 " valueSize=%" PRId32 "\n",
                       slots, key_size, value_size);
                exit_code = 0;
            }
        }
        if (exit_code) fprintf(stderr, "Invalid Weaver config: status=%d size=%" PRId32 "\n",
                               status, size);
    }
    alarm(0);
    if (result) AStatus_delete(result);
    if (request) AParcel_delete(request);
    if (reply) AParcel_delete(reply);
    AIBinder_decStrong(binder);
    dlclose(library);
    return exit_code;
}
