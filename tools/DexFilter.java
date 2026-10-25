import com.android.tools.smali.dexlib2.DexFileFactory;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MethodImplementation;
import com.android.tools.smali.dexlib2.immutable.ImmutableClassDef;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethod;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethodImplementation;
import com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction;
import com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction10x;
import com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction11n;
import com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction11x;
import com.android.tools.smali.dexlib2.writer.io.FileDataStore;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class DexFilter {
    public static void main(String[] args) throws Exception {
        String in = args[0], out = args[1], prefix = args[2];
        DexBackedDexFile dex = DexFileFactory.loadDexFile(in, Opcodes.forApi(29));
        DexPool pool = new DexPool(dex.getOpcodes());
        int kept = 0;
        for (ClassDef def : dex.getClasses()) {
            if (!def.getType().startsWith(prefix)) {
                continue;
            }
            kept++;
            List<Method> methods = new ArrayList<>();
            for (Method m : def.getMethods()) {
                methods.add(stubIfNeeded(def.getType(), m));
            }
            pool.internClass(new ImmutableClassDef(
                    def.getType(), def.getAccessFlags(), def.getSuperclass(),
                    def.getInterfaces(), def.getSourceFile(), def.getAnnotations(),
                    def.getFields(), methods));
            System.out.println("keep " + def.getType());
        }
        pool.writeTo(new FileDataStore(new File(out)));
        System.out.println("kept " + kept + " classes -> " + out);
    }

    private static Method stubIfNeeded(String type, Method m) {
        boolean grabConfig = type.equals("Lcom/nothing/onlineconfig/ConfigGrabber;")
                && m.getName().equals("grabConfig");
        boolean register = type.equals("Lcom/nothing/onlineconfig/ConfigObserver;")
                && m.getName().equals("register");
        if (!grabConfig && !register) {
            return m;
        }
        List<ImmutableInstruction> insns;
        int registers;
        if (grabConfig) {
            // const/4 v0, null ; return-object v0
            insns = List.of(
                    new ImmutableInstruction11n(Opcode.CONST_4, 0, 0),
                    new ImmutableInstruction11x(Opcode.RETURN_OBJECT, 0));
            registers = 1;
        } else {
            insns = List.of(new ImmutableInstruction10x(Opcode.RETURN_VOID));
            registers = 1;
        }
        MethodImplementation impl = new ImmutableMethodImplementation(
                registers, insns, Collections.emptyList(), Collections.emptyList());
        System.out.println("stub " + type + "." + m.getName());
        return new ImmutableMethod(type, m.getName(), m.getParameters(), m.getReturnType(),
                m.getAccessFlags(), m.getAnnotations(), Collections.emptySet(), impl);
    }
}
