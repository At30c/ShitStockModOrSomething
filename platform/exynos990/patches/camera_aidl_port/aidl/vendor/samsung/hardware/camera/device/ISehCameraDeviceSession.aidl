// Reconstruído de system/lib64/vendor.samsung.hardware.camera.device-V1-ndk.so
// (descriptor, transação 1 com uma String, versão 1, hash c1d37123...).
// O CameraService o obtém com AIBinder_getExtension() da ICameraDeviceSession.
package vendor.samsung.hardware.camera.device;

@VintfStability
interface ISehCameraDeviceSession {
    void setParameters(in String parameters);
}
