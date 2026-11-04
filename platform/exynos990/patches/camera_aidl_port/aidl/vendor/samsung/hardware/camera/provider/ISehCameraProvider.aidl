// Reconstruído de system/lib64/vendor.samsung.hardware.camera.provider-V1-ndk.so
// (descriptor, transação 1 sem argumentos, versão 1, hash 1b4ed917...).
// O CameraService o obtém com AIBinder_getExtension() do ICameraProvider.
package vendor.samsung.hardware.camera.provider;

@VintfStability
interface ISehCameraProvider {
    String[] getCameraIdListAll();
}
