import java.net.InetSocketAddress;
import java.net.Socket;

public class NetworkProbe {
    public static void main(String[] args) throws Exception {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress("10.96.0.1", 443), 1000);
            System.out.println("NETWORK_REACHED");
        } catch (Exception expected) {
            System.out.println("NETWORK_DENIED:" + expected.getClass().getSimpleName());
        }
    }
}
