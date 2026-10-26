//go:build android

package main

/*
#include <stdlib.h>
#include <android/log.h>

static void android_log(const char* msg) {
    __android_log_print(ANDROID_LOG_DEBUG, "GoTorrent", "%s", msg);
}
*/
import "C"
import "unsafe"

// 输出日志到 logcat
func Log(msg string) {
	cMsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cMsg))
	C.android_log(cMsg)
}
