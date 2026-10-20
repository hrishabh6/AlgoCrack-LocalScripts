import java.nio.file.Files;
import java.nio.file.Path;

public class FileProbe {
    public static void main(String[] args) throws Exception {
        for (String candidate : new String[]{"/runner-secret/value", "/etc/shadow", "/workspace"}) {
            System.out.println(candidate + ":" + Files.exists(Path.of(candidate)));
        }
    }
}
