package com.fugood.screencapture;

import androidx.annotation.Nullable;

import com.facebook.react.BaseReactPackage;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.module.model.ReactModuleInfo;
import com.facebook.react.module.model.ReactModuleInfoProvider;

import java.util.HashMap;
import java.util.Map;

public class ScreenCapturePackage extends BaseReactPackage {

    @Nullable
    @Override
    public NativeModule getModule(String name, ReactApplicationContext reactContext) {
        if (ScreenCaptureModule.NAME.equals(name)) {
            return new ScreenCaptureModule(reactContext);
        }
        return null;
    }

    @Override
    public ReactModuleInfoProvider getReactModuleInfoProvider() {
        return () -> {
            Map<String, ReactModuleInfo> map = new HashMap<>();
            map.put(
                ScreenCaptureModule.NAME,
                new ReactModuleInfo(
                    ScreenCaptureModule.NAME,
                    ScreenCaptureModule.NAME,
                    false, // canOverrideExistingModule
                    false, // needsEagerInit
                    false, // isCxxModule
                    BuildConfig.IS_NEW_ARCHITECTURE_ENABLED
                )
            );
            return map;
        };
    }
}
