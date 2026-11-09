package com.idm.fotaagent.enabler.ui;
import com.idm.fotaagent.BundleWrapper; import com.idm.fotaagent.enabler.ui.interfaces.IDMUIEventInterface;
public enum IDMUIManager { X; public static IDMUIManager getInstance(){return null;}
 public void sendActivityMessageDelayed(IDMUIEventInterface.UIACTIVITY a, BundleWrapper b, long d){}
 public void sendDialogMessage(IDMUIEventInterface.UIDIALOG d){} }
